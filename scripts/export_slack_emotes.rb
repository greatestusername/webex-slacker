#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "optparse"
require "time"
require "uri"

USER_AGENT = "webex-emote-paster/0.1"
SUPPORTED_EXTENSIONS = %w[png jpg jpeg gif webp].freeze
CONTENT_TYPE_EXTENSIONS = {
  "image/png" => "png",
  "image/jpeg" => "jpg",
  "image/gif" => "gif",
  "image/webp" => "webp"
}.freeze

options = {
  config: "emotes.generated.json",
  download_dir: "slack-emotes",
  include_aliases: true,
  include_categories: false,
  mode: "auto",
  overwrite: true,
  send: false
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: SLACK_TOKEN=TOKEN scripts/export_slack_emotes.rb [options]"

  opts.on("--config PATH", "Output emotes config JSON path (default: emotes.generated.json)") do |value|
    options[:config] = value
  end

  opts.on("--download-dir PATH", "Directory for downloaded Slack emoji files (default: slack-emotes)") do |value|
    options[:download_dir] = value
  end

  opts.on("--token-file PATH", "Read Slack token from a file instead of SLACK_TOKEN") do |value|
    options[:token_file] = value
  end

  opts.on("--input PATH", "Use a saved emoji.list JSON response instead of calling Slack") do |value|
    options[:input] = value
  end

  opts.on("--manifest PATH", "Output manifest path (default: DOWNLOAD_DIR/manifest.json)") do |value|
    options[:manifest] = value
  end

  opts.on("--mode MODE", %w[auto image file], "Config mode: auto, image, or file (default: auto)") do |value|
    options[:mode] = value
  end

  opts.on("--send", "Set send=true for generated emote entries") do
    options[:send] = true
  end

  opts.on("--no-aliases", "Skip Slack alias entries") do
    options[:include_aliases] = false
  end

  opts.on("--include-categories", "Ask Slack to include Unicode emoji categories") do
    options[:include_categories] = true
  end

  opts.on("--no-overwrite", "Reuse existing downloaded files") do
    options[:overwrite] = false
  end

  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit
  end
end

parser.parse!

def abort_with(message)
  warn "error: #{message}"
  exit 1
end

def read_json_file(path)
  JSON.parse(File.read(path))
rescue Errno::ENOENT
  abort_with("file not found: #{path}")
rescue JSON::ParserError => e
  abort_with("invalid JSON in #{path}: #{e.message}")
end

def slack_token(options)
  return ENV["SLACK_TOKEN"].strip if ENV["SLACK_TOKEN"] && !ENV["SLACK_TOKEN"].strip.empty?

  return nil unless options[:token_file]

  File.read(options[:token_file]).strip
rescue Errno::ENOENT
  abort_with("token file not found: #{options[:token_file]}")
end

def http_request(uri, limit = 5)
  abort_with("too many redirects while fetching #{uri}") if limit <= 0

  response = Net::HTTP.start(
    uri.hostname,
    uri.port,
    use_ssl: uri.scheme == "https",
    open_timeout: 15,
    read_timeout: 60
  ) do |http|
    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = USER_AGENT
    http.request(request)
  end

  case response
  when Net::HTTPRedirection
    location = response["location"]
    abort_with("redirect without Location header from #{uri}") unless location

    http_request(URI.join(uri, location), limit - 1)
  else
    response
  end
end

def fetch_slack_emoji(token, include_categories)
  uri = URI("https://slack.com/api/emoji.list")
  uri.query = URI.encode_www_form(include_categories: include_categories ? "true" : "false")

  response = Net::HTTP.start(
    uri.hostname,
    uri.port,
    use_ssl: true,
    open_timeout: 15,
    read_timeout: 60
  ) do |http|
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{token}"
    request["User-Agent"] = USER_AGENT
    http.request(request)
  end

  abort_with("Slack API returned HTTP #{response.code}: #{response.body}") unless response.is_a?(Net::HTTPSuccess)

  data = JSON.parse(response.body)
  return data if data["ok"]

  details = [data["error"], data["needed"] && "needed=#{data["needed"]}", data["provided"] && "provided=#{data["provided"]}"].compact
  abort_with("Slack emoji.list failed: #{details.join(", ")}")
rescue JSON::ParserError => e
  abort_with("Slack API returned invalid JSON: #{e.message}")
end

def emoji_map_from(data)
  source = data["emoji"] || data
  abort_with("input does not contain an emoji map") unless source.is_a?(Hash)

  source
end

def valid_alias_name?(name)
  name.match?(/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/)
end

def safe_filename(name)
  name.gsub(/[^A-Za-z0-9_-]/, "_")
end

def url_value?(value)
  value.is_a?(String) && value.match?(/\Ahttps?:\/\//)
end

def alias_value?(value)
  value.is_a?(String) && value.start_with?("alias:")
end

def alias_target(value)
  value.delete_prefix("alias:")
end

def extension_from(response, url)
  uri = URI(url)
  ext = File.extname(uri.path).delete_prefix(".").downcase
  return ext if SUPPORTED_EXTENSIONS.include?(ext)

  content_type = response["content-type"].to_s.split(";").first
  CONTENT_TYPE_EXTENSIONS.fetch(content_type, "png")
end

def emote_mode(ext, requested_mode)
  return requested_mode unless requested_mode == "auto"

  ext == "gif" ? "file" : "image"
end

def resolve_direct_name(name, emoji, seen = [])
  return nil if seen.include?(name)

  value = emoji[name]
  return name if url_value?(value)
  return nil unless alias_value?(value)

  resolve_direct_name(alias_target(value), emoji, seen + [name])
end

def write_json(path, data)
  FileUtils.mkdir_p(File.dirname(File.expand_path(path)))
  File.write(path, "#{JSON.pretty_generate(data)}\n")
end

token = slack_token(options)
data = if options[:input]
         read_json_file(options[:input])
       else
         abort_with("set SLACK_TOKEN or pass --token-file unless using --input") unless token

         fetch_slack_emoji(token, options[:include_categories])
       end

emoji = emoji_map_from(data)
download_dir = File.expand_path(options[:download_dir])
FileUtils.mkdir_p(download_dir)

downloaded = {}
warnings = []

emoji.sort.each do |name, value|
  next unless url_value?(value)

  unless valid_alias_name?(name)
    warnings << "skipped invalid Slack emoji name #{name.inspect}"
    next
  end

  begin
    response = http_request(URI(value))
    unless response.is_a?(Net::HTTPSuccess)
      warnings << "failed to download #{name}: HTTP #{response.code}"
      next
    end

    ext = extension_from(response, value)
    path = File.join(download_dir, "#{safe_filename(name)}.#{ext}")
    File.binwrite(path, response.body) if options[:overwrite] || !File.exist?(path)
    downloaded[name] = {
      "path" => File.expand_path(path),
      "url" => value,
      "ext" => ext
    }
  rescue StandardError => e
    warnings << "failed to download #{name}: #{e.class}: #{e.message}"
  end
end

config = {}
emoji.keys.sort.each do |name|
  value = emoji[name]
  next if alias_value?(value) && !options[:include_aliases]

  unless valid_alias_name?(name)
    warnings << "skipped invalid alias name #{name.inspect}"
    next
  end

  direct_name = resolve_direct_name(name, emoji)
  unless direct_name && downloaded[direct_name]
    warnings << "skipped #{name}: could not resolve downloadable emoji"
    next
  end

  ext = downloaded[direct_name]["ext"]
  config[":#{name}:"] = {
    "path" => downloaded[direct_name]["path"],
    "mode" => emote_mode(ext, options[:mode]),
    "send" => options[:send]
  }
end

write_json(options[:config], config)

manifest_path = options[:manifest] || File.join(download_dir, "manifest.json")
manifest = {
  "generated_at" => Time.now.utc.iso8601,
  "source" => options[:input] ? File.expand_path(options[:input]) : "Slack emoji.list",
  "emoji_count" => emoji.length,
  "downloaded_count" => downloaded.length,
  "config_count" => config.length,
  "downloaded" => downloaded,
  "warnings" => warnings
}
write_json(manifest_path, manifest)

warnings.each { |warning| warn "warning: #{warning}" }

puts "Downloaded #{downloaded.length} Slack emoji files to #{download_dir}"
puts "Wrote #{config.length} Hammerspoon aliases to #{File.expand_path(options[:config])}"
puts "Wrote manifest to #{File.expand_path(manifest_path)}"
