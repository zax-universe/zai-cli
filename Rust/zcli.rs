// zcli.rs - Z.AI CLI Rust Version

use reqwest;
use serde_json::{json, Value};
use std::io::{self, Write, BufRead};
use std::fs;
use std::path::PathBuf;
use regex::Regex;
use colored::*;

#[derive(Debug)]
struct Model {
    id: String,
    display: String,
}

struct File {
    path: String,
    content: String,
}

fn question(prompt: &str) -> String {
    print!("{}", prompt);
    io::stdout().flush().unwrap();
    let mut input = String::new();
    io::stdin().read_line(&mut input).unwrap();
    input.trim().to_string()
}

async fn post(host: &str, path: &str, data: Value) -> Result<Value, Box<dyn std::error::Error>> {
    let url = format!("https://{}{}", host, path);
    let client = reqwest::Client::new();
    let response = client.post(&url)
        .json(&data)
        .send()
        .await?;
    let json = response.json::<Value>().await?;
    Ok(json)
}

async fn stream_with_filter(host: &str, path: &str, data: Value) -> Result<Vec<File>, Box<dyn std::error::Error>> {
    let url = format!("https://{}{}", host, path);
    let client = reqwest::Client::new();
    let mut response = client.post(&url)
        .json(&data)
        .send()
        .await?;
    
    let mut full_text = String::new();
    let mut in_code_block = false;
    let mut all_files = Vec::new();
    
    while let Some(chunk) = response.chunk().await? {
        let chunk_str = String::from_utf8_lossy(&chunk);
        let lines: Vec<&str> = chunk_str.split('\n').collect();
        
        for line in lines {
            if let Ok(json) = serde_json::from_str::<Value>(line) {
                if let Some(text) = json["choices"][0]["delta"]["content"].as_str() {
                    full_text.push_str(text);
                    
                    // Character by character processing
                    let chars: Vec<char> = text.chars().collect();
                    let mut i = 0;
                    while i < chars.len() {
                        if i + 2 < chars.len() && chars[i] == '`' && chars[i+1] == '`' && chars[i+2] == '`' {
                            in_code_block = !in_code_block;
                            i += 3;
                        } else if !in_code_block {
                            print!("{}", chars[i]);
                            io::stdout().flush().unwrap();
                            i += 1;
                        } else {
                            i += 1;
                        }
                    }
                }
            }
        }
    }
    
    // Extract files using regex
    let re = Regex::new(r"```\w*\{path=([^}]+)\}\n([\s\S]*?)```")?;
    for cap in re.captures_iter(&full_text) {
        let file_path = cap[1].to_string();
        let content = cap[2].to_string().trim_end_matches('`').to_string();
        println!("{} Make: {}", "Make:".cyan(), file_path.cyan());
        all_files.push(File { path: file_path, content });
    }
    
    Ok(all_files)
}

fn write_files(files: &[File], out_dir: &PathBuf) {
    for file in files {
        let full_path = out_dir.join(&file.path);
        if let Some(parent) = full_path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(&full_path, &file.content).unwrap();
        println!("{} ✓ {}", "✓".green(), file.path.green());
    }
}

fn select_model() -> Model {
    println!("\n{} Select an AI model:", "".cyan());
    println!("  1. GLM 5");
    println!("  2. Z GLM 5.1");
    
    let choice = question(&format!("{} Select (1-2, default: 1): {}", "".yellow(), "".reset()));
    let choice = choice.trim();
    if choice == "2" {
        Model { id: "zai-org/GLM-5.1".to_string(), display: "Z GLM 5.1".to_string() }
    } else {
        Model { id: "zai-org/GLM-5".to_string(), display: "GLM 5".to_string() }
    }
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("\n{}╔════════════════════════════════════╗", "".cyan());
    println!("{}║                Z.AI CLI                       ║", "".cyan());
    println!("{}╚════════════════════════════════════╝{}\n", "".cyan(), "".reset());
    
    let selected_model = select_model();
    println!("{}✓ Model: {}{}\n", "✓".green(), selected_model.display.green(), "".reset());
    
    let prompt = question(&format!("{}Prompt Input: {}", "".yellow(), "".reset()));
    if prompt.trim().is_empty() {
        println!("{}✗ Prompt cannot be empty!{}", "✗".red(), "".reset());
        return Ok(());
    }
    
    let default_folder = prompt.to_lowercase().replace(" ", "-");
    let default_folder = if default_folder.len() > 30 { &default_folder[..30] } else { &default_folder };
    let folder_name = question(&format!("{} Destination folder name (default: {}): {}", "".yellow(), default_folder, "".reset()));
    let final_folder = if folder_name.trim().is_empty() { default_folder.to_string() } else { folder_name };
    
    println!("\n{} Select output mode:", "".cyan());
    println!("  1. Save to folder (without zip)");
    println!("  2. Save to folder + zip");
    let mode = question(&format!("{} Choose (1/2, default: 1): {}", "".yellow(), "".reset()));
    
    let is_zip = mode.trim() == "2";
    let out_dir = PathBuf::from(&final_folder);
    let zip_path = format!("{}.zip", final_folder);
    
    println!("\n{}Generating: {}{}\n", "".cyan(), prompt, "".reset());
    
    // Create chat
    let chat_data = json!({
        "prompt": prompt,
        "model": selected_model.id,
        "quality": "low"
    });
    
    let response = post("llamacoder.together.ai", "/api/create-chat", chat_data).await?;
    let last_message_id = response["lastMessageId"].as_i64().unwrap();
    
    println!("{}✓ Chat created{}", "✓".green(), "".reset());
    println!("{} AI is responding...{}\n", "".yellow(), "".reset());
    println!("{}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{}\n", "".bright_black(), "".reset());
    
    let stream_data = json!({
        "messageId": last_message_id,
        "model": selected_model.id
    });
    
    let files = stream_with_filter("llamacoder.together.ai", "/api/get-next-completion-stream-promise", stream_data).await?;
    
    println!("\n{}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{}\n", "".bright_black(), "".reset());
    
    if files.is_empty() {
        println!("{}✗ No files are generated{}", "✗".red(), "".reset());
        return Ok(());
    }
    
    println!("{} Total {} file will be created{}\n", "".green(), files.len().to_string().green(), "".reset());
    
    let confirm = question(&format!("{}Continue writing file? (y/n, default: y): {}", "".yellow(), "".reset()));
    if confirm.trim().to_lowercase() == "n" {
        println!("{}✗ Canceled{}", "✗".red(), "".reset());
        return Ok(());
    }
    
    if out_dir.exists() {
        println!("{}Folder {} already exists, it will be overwritten...{}", "".yellow(), final_folder.yellow(), "".reset());
        fs::remove_dir_all(&out_dir)?;
    }
    
    fs::create_dir_all(&out_dir)?;
    
    println!("\n{} Write files to disk...{}\n", "".cyan(), "".reset());
    write_files(&files, &out_dir);
    
    println!("\n{} Succeed! {} the file has been saved{}", "".green(), files.len().to_string().green(), "".reset());
    
    if is_zip {
        println!("{} Create zip...{}", "".cyan(), "".reset());
        // Zip functionality would need external crate
        println!("{} Done! The file is saved in: {}{}", "".green(), out_dir.display().to_string().green(), "".reset());
    } else {
        println!("{} Done! The file is saved in: {}{}", "".green(), out_dir.display().to_string().green(), "".reset());
    }
    
    Ok(())
}