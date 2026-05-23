#!/bin/bash
# zcli.sh - Z.AI CLI Bash Version

set -e

# Colors
CYAN='\033[36m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
GRAY='\033[90m'
RESET='\033[0m'

# State variables
IN_CODE_BLOCK=false
FULL_TEXT=""
declare -a FILE_PATHS
declare -a FILE_CONTENTS

select_model() {
    echo -e "\n${CYAN} Select an AI model:${RESET}"
    echo "  1. GLM 5"
    echo "  2. Z GLM 5.1"
    read -p "$(echo -e ${YELLOW} Select (1-2, default: 1): ${RESET})" choice
    choice=${choice:-1}
    if [ "$choice" = "2" ]; then
        echo "zai-org/GLM-5.1|GLM 5.1"
    else
        echo "zai-org/GLM-5|GLM 5"
    fi
}

post() {
    local host="$1"
    local path="$2"
    local data="$3"
    
    curl -s -X POST "https://${host}${path}" \
        -H "Content-Type: application/json" \
        -d "$data"
}

stream_with_filter() {
    local host="$1"
    local path="$2"
    local data="$3"
    
    IN_CODE_BLOCK=false
    FULL_TEXT=""
    
    curl -s -N -X POST "https://${host}${path}" \
        -H "Content-Type: application/json" \
        -d "$data" | while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            # Try to parse JSON
            if echo "$line" | jq -e . >/dev/null 2>&1; then
                text=$(echo "$line" | jq -r '.choices[0].delta.content // empty')
                if [[ -n "$text" ]]; then
                    FULL_TEXT="${FULL_TEXT}${text}"
                    
                    # Process character by character
                    i=0
                    while [[ $i -lt ${#text} ]]; do
                        char="${text:$i:1}"
                        # Check for ```
                        if [[ "${text:$i:3}" == '```' ]]; then
                            if [[ "$IN_CODE_BLOCK" == "false" ]]; then
                                IN_CODE_BLOCK=true
                            else
                                IN_CODE_BLOCK=false
                            fi
                            i=$((i+3))
                        elif [[ "$IN_CODE_BLOCK" == "false" ]]; then
                            echo -n "$char"
                            i=$((i+1))
                        else
                            i=$((i+1))
                        fi
                    done
                fi
            fi
        fi
    done
    
    # Extract files from FULL_TEXT
    echo "$FULL_TEXT" > /tmp/zcli_fulltext.txt
    
    # Extract file paths and contents
    while IFS= read -r match; do
        if [[ -n "$match" ]]; then
            file_path=$(echo "$match" | sed -n 's/.*{path=\([^}]*\)}.*/\1/p')
            content=$(echo "$match" | sed 's/```[^{]*{path=[^}]*}\n//; s/```$//')
            if [[ -n "$file_path" ]]; then
                echo "FILE:$file_path"
                echo "CONTENT:$content"
            fi
        fi
    done < <(grep -oP '```\w*\{path=[^}]+\}\n[\s\S]*?```' /tmp/zcli_fulltext.txt)
}

write_files() {
    local out_dir="$1"
    shift
    local files=("$@")
    
    for file in "${files[@]}"; do
        if [[ "$file" == FILE:* ]]; then
            file_path="${file#FILE:}"
            # Read next line for content
            read content_line
            if [[ "$content_line" == CONTENT:* ]]; then
                content="${content_line#CONTENT:}"
                full_path="${out_dir}/${file_path}"
                mkdir -p "$(dirname "$full_path")"
                echo -e "$content" > "$full_path"
                echo -e "${GREEN}✓ ${file_path}${RESET}"
            fi
        fi
    done
}

main() {
    echo -e "\n${CYAN}╔════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║                Z.AI CLI                       ║${RESET}"
    echo -e "${CYAN}╚════════════════════════════════════╝${RESET}\n"
    
    model_info=$(select_model)
    model_id=$(echo "$model_info" | cut -d'|' -f1)
    model_name=$(echo "$model_info" | cut -d'|' -f2)
    echo -e "${GREEN}✓ Model: ${model_name}${RESET}\n"
    
    read -p "$(echo -e ${YELLOW}Prompt Input: ${RESET})" prompt
    if [[ -z "$prompt" ]]; then
        echo -e "${RED}✗ Prompt cannot be empty!${RESET}"
        exit 1
    fi
    
    default_folder=$(echo "$prompt" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | cut -c1-30)
    read -p "$(echo -e ${YELLOW} Destination folder name (default: ${default_folder}): ${RESET})" folder_name
    final_folder="${folder_name:-$default_folder}"
    
    echo -e "\n${CYAN} Select output mode:${RESET}"
    echo "  1. Save to folder (without zip)"
    echo "  2. Save to folder + zip"
    read -p "$(echo -e ${YELLOW} Choose (1/2, default: 1): ${RESET})" mode
    
    is_zip=false
    if [[ "$mode" == "2" ]]; then
        is_zip=true
    fi
    
    out_dir="${final_folder}"
    zip_path="${final_folder}.zip"
    
    echo -e "\n${CYAN}Generating: ${prompt}${RESET}\n"
    
    # Create chat
    chat_data="{\"prompt\":\"${prompt}\",\"model\":\"${model_id}\",\"quality\":\"low\"}"
    response=$(post "llamacoder.together.ai" "/api/create-chat" "$chat_data")
    
    chat_id=$(echo "$response" | jq -r '.chatId')
    last_message_id=$(echo "$response" | jq -r '.lastMessageId')
    
    echo -e "${GREEN}✓ Chat created${RESET}"
    echo -e "${YELLOW} AI is responding...${RESET}\n"
    echo -e "${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
    
    # Stream
    stream_data="{\"messageId\":${last_message_id},\"model\":\"${model_id}\"}"
    stream_with_filter "llamacoder.together.ai" "/api/get-next-completion-stream-promise" "$stream_data"
    
    echo -e "\n${GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
    
    # Check if files were extracted
    if [[ ! -s /tmp/zcli_files.txt ]]; then
        echo -e "${RED}✗ No files are generated${RESET}"
        exit 1
    fi
    
    file_count=$(grep -c "^FILE:" /tmp/zcli_files.txt)
    echo -e "${GREEN} Total ${file_count} file will be created${RESET}\n"
    
    read -p "$(echo -e ${YELLOW}Continue writing file? (y/n, default: y): ${RESET})" confirm
    if [[ "${confirm,,}" == "n" ]]; then
        echo -e "${RED}✗ Canceled${RESET}"
        exit 1
    fi
    
    if [[ -d "$out_dir" ]]; then
        echo -e "${YELLOW}Folder ${final_folder} already exists, it will be overwritten...${RESET}"
        rm -rf "$out_dir"
    fi
    
    mkdir -p "$out_dir"
    
    echo -e "\n${CYAN} Write files to disk...${RESET}\n"
    
    # Process extracted files
    while IFS= read -r line; do
        if [[ "$line" == FILE:* ]]; then
            file_path="${line#FILE:}"
            # Read next line for content
            read content_line
            if [[ "$content_line" == CONTENT:* ]]; then
                content="${content_line#CONTENT:}"
                full_path="${out_dir}/${file_path}"
                mkdir -p "$(dirname "$full_path")"
                echo "$content" > "$full_path"
                echo -e "${GREEN}✓ ${file_path}${RESET}"
            fi
        fi
    done < /tmp/zcli_files.txt
    
    echo -e "\n${GREEN} Succeed! ${file_count} the file has been saved${RESET}"
    
    if [[ "$is_zip" == true ]]; then
        echo -e "${CYAN} Create zip...${RESET}"
        if command -v zip &> /dev/null; then
            cd "$(dirname "$out_dir")"
            zip -r "$(basename "$zip_path")" "$(basename "$out_dir")" > /dev/null 2>&1
            echo -e "${GREEN}✓ Zip created successfully: ${zip_path}${RESET}"
            
            read -p "$(echo -e ${YELLOW} Delete folder after zipping? (y/n, default: y): ${RESET})" delete_folder
            if [[ "${delete_folder,,}" != "n" ]]; then
                rm -rf "$out_dir"
                echo -e "${GREEN}✓ Folder ${final_folder} deleted${RESET}"
            else
                echo -e "${GREEN}✓ Permanent folders are stored in: ${out_dir}${RESET}"
            fi
        else
            echo -e "${YELLOW} Failed to create zip (zip not installed), files remain in folder: ${out_dir}${RESET}"
        fi
    else
        echo -e "${GREEN} Done! The file is saved in: ${out_dir}${RESET}"
    fi
    
    # Cleanup
    rm -f /tmp/zcli_fulltext.txt /tmp/zcli_files.txt
}

main "$@"