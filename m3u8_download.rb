#!/usr/bin/env ruby
require "net/http"
require "uri"
require 'digest'
require 'open3'


def redirect_url(response)
  if response['location'].nil?
    response.body.match(/<a href=\"([^>]+)\">/i)[1]
  else
    response['location']
  end
end

# Arguments.
url = ARGV[0]
path = ARGV[1]
@cookie = ARGV[2] ? ARGV[2] : ""# optional

unless url && path 
  # URL and path are required parameters. 
  puts "Usage: "
  puts "    ruby m3u8_download.rb <url> <path> <cookie - optional>"
  exit 0
end
  
url = URI::encode(url) if url.include?(" ") || url.include?("|") || url.include?("~")  
uri = URI.parse(url)
ts_file = nil
m3u8_file = nil

puts "-> Requesting m3u8 file."
http = Net::HTTP.new(uri.host, uri.port)

if url.include?("https")
  http.use_ssl = true
  http.verify_mode = OpenSSL::SSL::VERIFY_NONE # read into this
end

request = Net::HTTP::Get.new(uri.request_uri, {"Cookie" => @cookie})
response = http.request(request)
puts response.code
m3u8_main = response.body

puts "----\n\n\n"
puts "M3U8 Contents"
puts "----"
puts m3u8_main
puts "----\n\n\n"

@stream_info_count = 0
@stream_map = {}
cl = 0
@max = 0
m3u8_main.each_line do |s|
  if s.include?("EXT-X-STREAM") && s.include?("RESOLUTION") && cl == 0
    @resolution_width = s.split("RESOLUTION=")[-1].split(",")[0].split("x")[0].to_i
    puts "RESOLUTION #{@resolution_width}"
    @max = @max > @resolution_width ? @max : @resolution_width
    cl = 1
    next
  end
  if (s.downcase.include?("m3u8") || s.downcase.include?("mp4")) && @resolution_width
    @stream_map[@resolution_width] = s.strip
    cl = 0
    @resolution_width = nil
  end
end



puts "\n\n\n Max=#{@max}  Stream info  #{@stream_map} \n\n\n"

m3u8_main.each_line do |s|
  next if s[0] == "#"
  if s.downcase.include?("m3u8") || s.downcase.include?("mp4")
    if @stream_map.size > 0
      m3u8_file = @stream_map[@max]
      puts m3u8_file
      if !(m3u8_file.include?("http://") || m3u8_file.include?("https://"))
        m3u8split = url.split("/")
        puts "start"
        puts m3u8split
        m3u8split.delete_at(-1)
        puts m3u8split
        m3u8_file = m3u8split.join("/") + "/" +  s
        puts m3u8_file
      end
    else
      m3u8_file = s
      if !(m3u8_file.include?("http://") || m3u8_file.include?("https://"))
        m3u8split = url.split("/")
        m3u8split.delete_at(-1)
        m3u8_file = m3u8split.join("/") + "/" +  s
      end
    end
    puts "-> M3U8 file selected: #{m3u8_file}\n"
    break
  elsif s.downcase.include?("ts")  
    ts_file = s
    puts "-> TS file: #{ts_file}\n"
    break
  end
end

if response["Set-Cookie"] && m3u8_file
  @cookie = response["Set-Cookie"]
  puts "-> New cookie: #{@cookie}"
end

if m3u8_file
  puts "-> Requesting new m3u8 file"
  uri1 = URI.parse(m3u8_file)
  http1 = Net::HTTP.new(uri1.host, uri1.port)
  
  if m3u8_file.include?("https")
    http1.use_ssl = true
    http1.verify_mode = OpenSSL::SSL::VERIFY_NONE # read into this
  end

  request1 = Net::HTTP::Get.new(uri1.request_uri, {"Cookie" => @cookie})
  response1 = http1.request(request1)
  m3u8_main = response1.body
  if response1["Set-Cookie"]
    @cookie = response1["Set-Cookie"]
    puts "-> New cookie : #{@cookie}"
  end
  puts "----\n\n\n"
  puts "M3U8 Contents"
  puts "----"
  puts m3u8_main
  puts "----\n\n\n"
end

original_file = ""
url = m3u8_file ? m3u8_file : url


key = nil
method = nil
sequence = 0

# Check if the TS is encrypted. If yes obtain the key.
m3u8_main.each_line do |s|

  # Get the key file
  if s.include?("#EXT-X-KEY")
    s = s.split("#EXT-X-KEY:")[1]
    method = s.split(",URI")[0].split("METHOD=")[1]
    key = s.split(",URI=")[1].gsub("\"", "")
    if key
      uri = URI.parse(key)
      httpk = Net::HTTP.new(uri.host, uri.port)

      request = Net::HTTP::Get.new(uri.request_uri, {"Cookie" => @cookie})
      response = httpk.request(request)
      key = response.body
    end
    puts "Method : #{method}"
    puts "Key : #{key}"
  end

  # Get the sequence for the IV.
  if s.include?("EXT-X-MEDIA-SEQUENCE")
    sequence = s.split(":")[1].to_i
    puts "Sequence: #{sequence}\n"
  end
end
sec_byte = 0

# TS file
m3u8_main.each_line do |s|
  s = s.strip
  next if s.start_with?("#")

  
  if !(s.include?("http://") || s.include?("https://"))
    m3u8split = url.split("/")
    puts m3u8split
    m3u8split.delete_at(-1)
    s = m3u8split.join("/") + "/" +  s
  end

  puts "TS File here : #{s} \n"

  if s.include?("isad=True")
    puts "xxxx Ad skip"
    next
  end
  
  response_content = nil 

  if !s.include?("_")
    uri1 = nil
    begin 
      uri1 = URI.parse(s)
    rescue => e
      host = s.match(".+\:\/\/([^\/]+)")[1]
      uri1 = URI.parse(s.sub(host, 'dummy-host'))
      uri1.instance_variable_set('@host', host)
    end


    http1 = Net::HTTP.new(uri1.host, uri1.port)
    request1 = Net::HTTP::Get.new(uri1.request_uri, {"Cookie" => @cookie})

    puts uri1.host
    puts uri1.port
    puts uri1.request_uri

    response1 = http1.request(request1)

    if response1.kind_of?(Net::HTTPRedirection)     
      redirection_url = redirect_url(response1)
      puts "Redirection URL #{redirection_url}"
      uri1 = URI.parse(redirection_url)
      http1 = Net::HTTP.new(uri1.host, uri1.port)
      request1 = Net::HTTP::Get.new(uri1.request_uri, {"Cookie" => @cookie})
      response1 = http1.request(request1)
    end
      response_content = response1.body
  else

    md5url = Digest::MD5.hexdigest(s)
    filemd5 = "/tmp/#{md5url}-#{sequence}"
    cmd = "curl \"#{s}\" -o #{filemd5}"

    Open3.popen3(cmd) do |stdin, stdout, stderr, wait_thr|
      puts "stdout is:" + stdout.read
      puts "stderr is:" + stderr.read
    end

    puts "extracting contents from file #{filemd5}" 
    response_content = File.read(filemd5)

    File.delete(filemd5) 
  end

  if key
    if method.downcase == "aes-128"
      if sequence > 256
        sec_byte = 1
        sequence = 0
      end
      aes = OpenSSL::Cipher.new('aes-128-cbc')
      aes.decrypt
      aes.key = key
      puts "Key applied: #{key}"
      puts "Sequence applied: #{sequence}"
      iv = [0,0,0,0,0,0,0,0,0,0,0,0,0,0, sec_byte,sequence].pack("C*")
      puts iv
      aes.iv = iv
      data1 = response_content
      data = aes.update(data1)
      original_file << data
    end
  else
    original_file << response_content
  end

  sequence = sequence + 1
end

if original_file && original_file.length > 0
  File.open("#{path}", 'w') {|f| f.write(original_file)}
end

puts "Finished downloading m3u8 file"



