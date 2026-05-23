#!/usr/bin/env ruby
# zcli.rb - Z.AI CLI Ruby Version

require 'json'
require 'net/http'
require 'uri'
require 'fileutils'
require 'zip'

# ANSI colors
CYAN = "\033[36m"
GREEN = "\033[32m"
YELLOW = "\033[33m"
RED = "\033[31m"
GRAY = "\033[90m"
RESET = "\033[0m"

AVAILABLE_MODELS = {
  "1" => { id: "zai-org/GLM-5", display: "GLM 5" },
  "2" => { id: "zai-org/GLM-5.1", display: "Z GLM 5.1" }
}

$in_code_block = false
$full_text = ""

def question(prompt)
  print prompt
  gets.chomp
end

def post(host, path, data)
  uri = URI.parse("https://#{host}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  
  request = Net::HTTP::Post.new(uri.path)
  request['Content-Type'] = 'application/json'
  request.body = data.to_json
  
  response = http.request(request)
  JSON.parse(response.body)
end

def stream_with_filter(host, path, data)
  uri = URI.parse("https://#{host}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  
  request = Net::HTTP::Post.new(uri.path)
  request['Content-Type'] = 'application/json'
  request.body = data.to_json
  
  all_files = []
  
  http.request(request) do |response|
    response.read_body do |chunk|
      chunk.each_line do |line|
        next if line.strip.empty?
        
        begin
          json = JSON.parse(line)
          text = json.dig('choices', 0, 'delta', 'content')
          
          if text
            $full_text += text
            
            # Character by character processing
            i = 0
            while i < text.length
              if i + 2 < text.length && text[i, 3] == '```'
                $in_code_block = !$in_code_block
                i += 3
              elsif !$in_code_block
                print text[i]
                STDOUT.flush
                i += 1
              else
                i += 1
              end
            end
          end
        rescue JSON::ParserError
          next
        end
      end
    end
  end
  
  # Extract files using regex
  regex = /```\w*\{path=([^}]+)\}\n([\s\S]*?)```/
  $full_text.scan(regex) do |match|
    file_path = match[0]
    content = match[1].gsub(/```$/, '').strip
    all_files << { path: file_path, content: content }
    puts "#{CYAN} Make: #{file_path}#{RESET}"
  end
  
  all_files
end

def write_files(files, out_dir)
  files.each do |file|
    full_path = File.join(out_dir, file[:path])
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, file[:content])
    puts "#{GREEN}✓ #{file[:path]}#{RESET}"
  end
end

def select_model
  puts "\n#{CYAN} Select an AI model:#{RESET}"
  puts "  1. GLM 5"
  puts "  2. Z GLM 5.1"
  
  choice = question("#{YELLOW} Select (1-2, default: 1): #{RESET}")
  choice = choice.strip.empty? ? "1" : choice
  AVAILABLE_MODELS[choice] || AVAILABLE_MODELS["1"]
end

def main
  puts "\n#{CYAN}╔════════════════════════════════════╗#{RESET}"
  puts "#{CYAN}║                Z.AI CLI                       ║#{RESET}"
  puts "#{CYAN}╚════════════════════════════════════╝#{RESET}\n"
  
  selected_model = select_model
  puts "#{GREEN}✓ Model: #{selected_model[:display]}#{RESET}\n"
  
  prompt = question("#{YELLOW}Prompt Input: #{RESET}")
  if prompt.strip.empty?
    puts "#{RED}✗ Prompt cannot be empty!#{RESET}"
    return
  end
  
  default_folder = prompt.gsub(/\s+/, '-').downcase[0, 30]
  folder_name = question("#{YELLOW} Destination folder name (default: #{default_folder}): #{RESET}")
  final_folder = folder_name.strip.empty? ? default_folder : folder_name
  
  puts "\n#{CYAN} Select output mode:#{RESET}"
  puts "  1. Save to folder (without zip)"
  puts "  2. Save to folder + zip"
  mode = question("#{YELLOW} Choose (1/2, default: 1): #{RESET}")
  
  is_zip = mode.strip == "2"
  out_dir = final_folder
  zip_path = "#{final_folder}.zip"
  
  puts "\n#{CYAN}Generating: #{prompt}#{RESET}\n"
  
  begin
    response = post("llamacoder.together.ai", "/api/create-chat", {
      prompt: prompt,
      model: selected_model[:id],
      quality: "low"
    })
    
    last_message_id = response['lastMessageId']
    
    puts "#{GREEN}✓ Chat created#{RESET}"
    puts "#{YELLOW} AI is responding...#{RESET}\n"
    puts "#{GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━#{RESET}\n"
    
    files = stream_with_filter("llamacoder.together.ai", 
      "/api/get-next-completion-stream-promise", 
      { messageId: last_message_id, model: selected_model[:id] })
    
    puts "\n#{GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━#{RESET}\n"
    
    if files.empty?
      puts "#{RED}✗ No files are generated#{RESET}"
      return
    end
    
    puts "#{GREEN} Total #{files.length} file will be created#{RESET}\n"
    
    confirm = question("#{YELLOW}Continue writing file? (y/n, default: y): #{RESET}")
    if confirm.strip.downcase == "n"
      puts "#{RED}✗ Canceled#{RESET}"
      return
    end
    
    if Dir.exist?(out_dir)
      puts "#{YELLOW}Folder #{final_folder} already exists, it will be overwritten...#{RESET}"
      FileUtils.rm_rf(out_dir)
    end
    
    FileUtils.mkdir_p(out_dir)
    
    puts "\n#{CYAN} Write files to disk...#{RESET}\n"
    write_files(files, out_dir)
    
    puts "\n#{GREEN} Succeed! #{files.length} the file has been saved#{RESET}"
    
    if is_zip
      puts "#{CYAN} Create zip...#{RESET}"
      begin
        Zip::File.open(zip_path, Zip::File::CREATE) do |zipfile|
          Dir[File.join(out_dir, '**', '**')].each do |file|
            zipfile.add(file.sub("#{out_dir}/", ''), file)
          end
        end
        puts "#{GREEN}✓ Zip created successfully: #{zip_path}#{RESET}"
        
        delete_folder = question("#{YELLOW} Delete folder after zipping? (y/n, default: y): #{RESET}")
        if delete_folder.strip.downcase != "n"
          FileUtils.rm_rf(out_dir)
          puts "#{GREEN}✓ Folder #{final_folder} deleted#{RESET}"
        else
          puts "#{GREEN}✓ Permanent folders are stored in: #{out_dir}#{RESET}"
        end
      rescue => e
        puts "#{YELLOW} Failed to create zip, files remain in folder: #{out_dir}#{RESET}"
      end
    else
      puts "#{GREEN} Done! The file is saved in: #{out_dir}#{RESET}"
    end
    
  rescue => e
    puts "#{RED}✗ Error: #{e.message}#{RESET}"
  end
end

main if __FILE__ == $0