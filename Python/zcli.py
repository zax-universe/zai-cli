#!/usr/bin/env python3

import json
import os
import re
import sys
import zipfile
import shutil
from pathlib import Path
import urllib.request
import urllib.error
from typing import List, Dict, Any, Optional

# Color codes for terminal
class Colors:
    CYAN = '\033[36m'
    GREEN = '\033[32m'
    YELLOW = '\033[33m'
    RED = '\033[31m'
    GRAY = '\033[90m'
    RESET = '\033[0m'

AVAILABLE_MODELS = {
    "1": {"id": "zai-org/GLM-5", "name": "Z GLM 5", "display": "GLM 5"},
    "2": {"id": "zai-org/GLM-5.1", "name": "GLM 5.1", "display": "Z GLM 5.1"}
}

def question(prompt: str) -> str:
    """Get input from user"""
    return input(prompt)

def post(host: str, path: str, data: Dict) -> Dict:
    """Make POST request"""
    body = json.dumps(data).encode('utf-8')
    url = f"https://{host}{path}"
    
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Content-Length": str(len(body))
        },
        method="POST"
    )
    
    try:
        with urllib.request.urlopen(req) as response:
            return json.loads(response.read().decode('utf-8'))
    except urllib.error.URLError as e:
        raise Exception(f"Request failed: {e}")

def stream_with_filter(host: str, path: str, data: Dict, on_progress: Optional[Dict] = None) -> List[Dict]:
    """Stream response and filter content"""
    body = json.dumps(data).encode('utf-8')
    url = f"https://{host}{path}"
    
    req = urllib.request.Request(
        url,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    
    full_text = ""
    in_code_block = False
    all_files = []
    
    try:
        with urllib.request.urlopen(req) as response:
            for line in response:
                line_str = line.decode('utf-8').strip()
                if not line_str:
                    continue
                    
                try:
                    j = json.loads(line_str)
                    text = j.get('choices', [{}])[0].get('delta', {}).get('content', '')
                    
                    if text:
                        full_text += text
                        
                        # Character by character processing
                        i = 0
                        while i < len(text):
                            # Check for code block markers
                            if text[i] == '`' and i + 2 < len(text) and text[i:i+3] == '```':
                                in_code_block = not in_code_block
                                i += 3
                            elif not in_code_block:
                                print(text[i], end='', flush=True)
                                i += 1
                            else:
                                i += 1
                                
                except json.JSONDecodeError:
                    continue
    
    except urllib.error.URLError as e:
        raise Exception(f"Stream failed: {e}")
    
    # Extract files from full text
    pattern = r'```\w*\{path=([^}]+)\}\n([\s\S]*?)```'
    matches = re.findall(pattern, full_text)
    
    for match in matches:
        file_path, content = match
        # Remove trailing backticks and clean up
        content = content.rstrip('`').strip()
        all_files.append({"path": file_path, "content": content})
        if on_progress and 'on_file_detected' in on_progress:
            on_progress['on_file_detected'](file_path)
    
    return all_files

def write_files(files: List[Dict], out_dir: Path):
    """Write files to disk"""
    for file in files:
        full_path = out_dir / file['path']
        full_path.parent.mkdir(parents=True, exist_ok=True)
        full_path.write_text(file['content'], encoding='utf-8')
        print(f"{Colors.GREEN}✓ {file['path']}{Colors.RESET}")

def create_zip(source_dir: Path, zip_path: Path):
    """Create zip archive"""
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
        for file_path in source_dir.rglob('*'):
            if file_path.is_file():
                arcname = file_path.relative_to(source_dir.parent)
                zipf.write(file_path, arcname)

def select_model() -> Dict:
    """Select AI model"""
    print(f"\n{Colors.CYAN} Select an AI model:{Colors.RESET}")
    for key, model in AVAILABLE_MODELS.items():
        print(f"  {key}. {model['display']}")
    
    choice = question(f"{Colors.YELLOW} Select (1-2, default: 1): {Colors.RESET}")
    selected_key = choice.strip() or "1"
    return AVAILABLE_MODELS.get(selected_key, AVAILABLE_MODELS["1"])

def main():
    print(f"\n{Colors.CYAN}╔════════════════════════════════════╗{Colors.RESET}")
    print(f"{Colors.CYAN}║                Z.AI CLI                       ║{Colors.RESET}")
    print(f"{Colors.CYAN}╚════════════════════════════════════╝{Colors.RESET}\n")
    
    selected_model = select_model()
    print(f"{Colors.GREEN}✓ Model: {selected_model['display']}{Colors.RESET}\n")
    
    prompt = question(f"{Colors.YELLOW}Prompt Input: {Colors.RESET}")
    if not prompt.strip():
        print(f"{Colors.RED}✗ Prompt cannot be empty!{Colors.RESET}")
        return
    
    # Create folder name from prompt
    default_folder = re.sub(r'\s+', '-', prompt.lower())[:30]
    folder_name = question(f"{Colors.YELLOW} Destination folder name (default: {default_folder}): {Colors.RESET}")
    final_folder = folder_name.strip() or default_folder
    
    print(f"\n{Colors.CYAN} Select output mode:{Colors.RESET}")
    print("  1. Save to folder (without zip)")
    print("  2. Save to folder + zip")
    mode = question(f"{Colors.YELLOW} Choose (1/2, default: 1): {Colors.RESET}")
    
    is_zip = mode.strip() == "2"
    out_dir = Path.cwd() / final_folder
    zip_path = Path.cwd() / f"{final_folder}.zip"
    
    print(f"\n{Colors.CYAN}Generating: {prompt}{Colors.RESET}\n")
    
    try:
        # Create chat
        response = post("llamacoder.together.ai", "/api/create-chat", {
            "prompt": prompt,
            "model": selected_model["id"],
            "quality": "low",
        })
        
        chat_id = response.get('chatId')
        last_message_id = response.get('lastMessageId')
        
        print(f"{Colors.GREEN}✓ Chat created{Colors.RESET}")
        print(f"{Colors.YELLOW} AI is responding...{Colors.RESET}\n")
        print(f"{Colors.GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{Colors.RESET}\n")
        
        def on_file_detected(file_path):
            print(f"{Colors.CYAN} Make: {file_path}{Colors.RESET}")
        
        files = stream_with_filter(
            "llamacoder.together.ai",
            "/api/get-next-completion-stream-promise",
            {"messageId": last_message_id, "model": selected_model["id"]},
            {"on_file_detected": on_file_detected}
        )
        
        print(f"\n{Colors.GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{Colors.RESET}\n")
        
        if len(files) == 0:
            print(f"{Colors.RED}✗ No files are generated{Colors.RESET}")
            return
        
        print(f"{Colors.GREEN} Total {len(files)} file will be created{Colors.RESET}\n")
        
        confirm = question(f"{Colors.YELLOW}Continue writing file? (y/n, default: y): {Colors.RESET}")
        if confirm.strip().lower() == "n":
            print(f"{Colors.RED}✗ Canceled{Colors.RESET}")
            return
        
        # Clean existing directory
        if out_dir.exists():
            print(f"{Colors.YELLOW}Folder {final_folder} already exists, it will be overwritten...{Colors.RESET}")
            shutil.rmtree(out_dir)
        
        out_dir.mkdir(parents=True, exist_ok=True)
        
        print(f"\n{Colors.CYAN} Write files to disk...{Colors.RESET}\n")
        write_files(files, out_dir)
        
        print(f"\n{Colors.GREEN} Succeed! {len(files)} the file has been saved{Colors.RESET}")
        
        if is_zip:
            print(f"{Colors.CYAN} Create zip...{Colors.RESET}")
            try:
                create_zip(out_dir, zip_path)
                print(f"{Colors.GREEN}✓ Zip created successfully: {zip_path}{Colors.RESET}")
                
                delete_folder = question(f"{Colors.YELLOW} Delete folder after zipping? (y/n, default: y): {Colors.RESET}")
                if delete_folder.strip().lower() != "n":
                    shutil.rmtree(out_dir)
                    print(f"{Colors.GREEN}✓ Folder {final_folder} deleted{Colors.RESET}")
                else:
                    print(f"{Colors.GREEN}✓ Permanent folders are stored in: {out_dir}{Colors.RESET}")
            except Exception as e:
                print(f"{Colors.YELLOW} Failed to create zip, files remain in folder: {out_dir}{Colors.RESET}")
        else:
            print(f"{Colors.GREEN} Done! The file is saved in: {out_dir}{Colors.RESET}")
        
    except Exception as error:
        print(f"{Colors.RED}✗ Error: {str(error)}{Colors.RESET}")

if __name__ == "__main__":
    main()