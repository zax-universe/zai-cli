// zcli.cpp - Z.AI CLI C++ Version

#include <iostream>
#include <string>
#include <vector>
#include <map>
#include <regex>
#include <fstream>
#include <sstream>
#include <cstdlib>
#include <filesystem>
#include <curl/curl.h>
#include <sys/stat.h>

#ifdef _WIN32
#include <direct.h>
#define mkdir _mkdir
#else
#include <sys/stat.h>
#endif

namespace fs = std::filesystem;

// ANSI colors
const std::string CYAN = "\033[36m";
const std::string GREEN = "\033[32m";
const std::string YELLOW = "\033[33m";
const std::string RED = "\033[31m";
const std::string GRAY = "\033[90m";
const std::string RESET = "\033[0m";

bool inCodeBlock = false;
std::string fullText = "";

struct Model {
    std::string id;
    std::string display;
};

struct File {
    std::string path;
    std::string content;
};

std::map<std::string, Model> availableModels = {
    {"1", {"zai-org/GLM-5", "GLM 5"}},
    {"2", {"zai-org/GLM-5.1", "Z GLM 5.1"}}
};

size_t WriteCallback(void* contents, size_t size, size_t nmemb, std::string* response) {
    size_t totalSize = size * nmemb;
    response->append((char*)contents, totalSize);
    return totalSize;
}

size_t StreamCallback(void* contents, size_t size, size_t nmemb, void* userp) {
    size_t totalSize = size * nmemb;
    std::string chunk((char*)contents, totalSize);
    std::istringstream iss(chunk);
    std::string line;
    
    while (std::getline(iss, line)) {
        if (line.empty()) continue;
        
        // Simple JSON parsing for content
        std::regex contentRegex("\"content\":\"([^\"]*)\"");
        std::smatch match;
        if (std::regex_search(line, match, contentRegex)) {
            std::string text = match[1];
            fullText += text;
            
            // Character by character processing
            for (size_t i = 0; i < text.length(); i++) {
                if (i + 2 < text.length() && text.substr(i, 3) == "```") {
                    inCodeBlock = !inCodeBlock;
                    i += 2;
                } else if (!inCodeBlock) {
                    std::cout << text[i];
                    std::cout.flush();
                }
            }
        }
    }
    
    return totalSize;
}

std::string post(const std::string& host, const std::string& path, const std::string& data) {
    CURL* curl = curl_easy_init();
    std::string response;
    
    if (curl) {
        std::string url = "https://" + host + path;
        curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, data.c_str());
        
        struct curl_slist* headers = nullptr;
        headers = curl_slist_append(headers, "Content-Type: application/json");
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, WriteCallback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
        
        curl_easy_perform(curl);
        curl_easy_cleanup(curl);
        curl_slist_free_all(headers);
    }
    
    return response;
}

void streamWithFilter(const std::string& host, const std::string& path, const std::string& data) {
    CURL* curl = curl_easy_init();
    
    if (curl) {
        std::string url = "https://" + host + path;
        curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, data.c_str());
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, StreamCallback);
        
        struct curl_slist* headers = nullptr;
        headers = curl_slist_append(headers, "Content-Type: application/json");
        curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
        
        curl_easy_perform(curl);
        curl_easy_cleanup(curl);
        curl_slist_free_all(headers);
    }
}

std::vector<File> extractFiles() {
    std::vector<File> files;
    std::regex fileRegex(R"(```\w*\{path=([^}]+)\}\n([\s\S]*?)```)");
    std::smatch match;
    std::string::const_iterator searchStart(fullText.cbegin());
    
    while (std::regex_search(searchStart, fullText.cend(), match, fileRegex)) {
        File file;
        file.path = match[1];
        file.content = match[2];
        // Remove trailing backticks
        if (!file.content.empty() && file.content.back() == '`') {
            file.content.pop_back();
        }
        files.push_back(file);
        std::cout << CYAN << " Make: " << file.path << RESET << std::endl;
        searchStart = match[0].second;
    }
    
    return files;
}

void writeFiles(const std::vector<File>& files, const std::string& outDir) {
    for (const auto& file : files) {
        fs::path fullPath = fs::path(outDir) / file.path;
        fs::create_directories(fullPath.parent_path());
        std::ofstream outFile(fullPath);
        outFile << file.content;
        outFile.close();
        std::cout << GREEN << "✓ " << file.path << RESET << std::endl;
    }
}

Model selectModel() {
    std::cout << "\n" << CYAN << " Select an AI model:" << RESET << std::endl;
    std::cout << "  1. GLM 5" << std::endl;
    std::cout << "  2. Z GLM 5.1" << std::endl;
    
    std::string choice;
    std::cout << YELLOW << " Select (1-2, default: 1): " << RESET;
    std::getline(std::cin, choice);
    
    if (choice.empty() || choice == "1") {
        return availableModels["1"];
    }
    return availableModels["2"];
}

std::string extractJsonValue(const std::string& json, const std::string& key) {
    std::regex keyRegex("\"" + key + "\":(\\d+)");
    std::smatch match;
    if (std::regex_search(json, match, keyRegex)) {
        return match[1];
    }
    return "0";
}

int main() {
    curl_global_init(CURL_GLOBAL_DEFAULT);
    
    std::cout << "\n" << CYAN << "╔════════════════════════════════════╗" << RESET << std::endl;
    std::cout << CYAN << "║                Z.AI CLI                       ║" << RESET << std::endl;
    std::cout << CYAN << "╚════════════════════════════════════╝" << RESET << "\n" << std::endl;
    
    Model selectedModel = selectModel();
    std::cout << GREEN << "✓ Model: " << selectedModel.display << RESET << "\n" << std::endl;
    
    std::string prompt;
    std::cout << YELLOW << "Prompt Input: " << RESET;
    std::getline(std::cin, prompt);
    
    if (prompt.empty()) {
        std::cout << RED << "✗ Prompt cannot be empty!" << RESET << std::endl;
        return 1;
    }
    
    std::string defaultFolder = prompt;
    std::replace(defaultFolder.begin(), defaultFolder.end(), ' ', '-');
    std::transform(defaultFolder.begin(), defaultFolder.end(), defaultFolder.begin(), ::tolower);
    if (defaultFolder.length() > 30) defaultFolder = defaultFolder.substr(0, 30);
    
    std::string folderName;
    std::cout << YELLOW << " Destination folder name (default: " << defaultFolder << "): " << RESET;
    std::getline(std::cin, folderName);
    std::string finalFolder = folderName.empty() ? defaultFolder : folderName;
    
    std::cout << "\n" << CYAN << " Select output mode:" << RESET << std::endl;
    std::cout << "  1. Save to folder (without zip)" << std::endl;
    std::cout << "  2. Save to folder + zip" << std::endl;
    
    std::string mode;
    std::cout << YELLOW << " Choose (1/2, default: 1): " << RESET;
    std::getline(std::cin, mode);
    
    bool isZip = (mode == "2");
    std::string outDir = finalFolder;
    std::string zipPath = finalFolder + ".zip";
    
    std::cout << "\n" << CYAN << "Generating: " << prompt << RESET << "\n" << std::endl;
    
    try {
        std::string chatData = "{\"prompt\":\"" + prompt + "\",\"model\":\"" + selectedModel.id + "\",\"quality\":\"low\"}";
        std::string response = post("llamacoder.together.ai", "/api/create-chat", chatData);
        
        std::string lastMessageId = extractJsonValue(response, "lastMessageId");
        
        std::cout << GREEN << "✓ Chat created" << RESET << std::endl;
        std::cout << YELLOW << " AI is responding..." << RESET << "\n" << std::endl;
        std::cout << GRAY << "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" << RESET << "\n" << std::endl;
        
        std::string streamData = "{\"messageId\":" + lastMessageId + ",\"model\":\"" + selectedModel.id + "\"}";
        streamWithFilter("llamacoder.together.ai", "/api/get-next-completion-stream-promise", streamData);
        
        std::cout << "\n" << GRAY << "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" << RESET << "\n" << std::endl;
        
        std::vector<File> files = extractFiles();
        
        if (files.empty()) {
            std::cout << RED << "✗ No files are generated" << RESET << std::endl;
            return 1;
        }
        
        std::cout << GREEN << " Total " << files.size() << " file will be created" << RESET << "\n" << std::endl;
        
        std::string confirm;
        std::cout << YELLOW << "Continue writing file? (y/n, default: y): " << RESET;
        std::getline(std::cin, confirm);
        
        if (confirm == "n") {
            std::cout << RED << "✗ Canceled" << RESET << std::endl;
            return 1;
        }
        
        if (fs::exists(outDir)) {
            std::cout << YELLOW << "Folder " << finalFolder << " already exists, it will be overwritten..." << RESET << std::endl;
            fs::remove_all(outDir);
        }
        
        fs::create_directories(outDir);
        
        std::cout << "\n" << CYAN << " Write files to disk..." << RESET << "\n" << std::endl;
        writeFiles(files, outDir);
        
        std::cout << "\n" << GREEN << " Succeed! " << files.size() << " the file has been saved" << RESET << std::endl;
        
        if (isZip) {
            std::cout << CYAN << " Create zip..." << RESET << std::endl;
            std::string zipCmd = "zip -r \"" + zipPath + "\" \"" + outDir + "\"";
            if (system(zipCmd.c_str()) == 0) {
                std::cout << GREEN << "✓ Zip created successfully: " << zipPath << RESET << std::endl;
                
                std::string deleteFolder;
                std::cout << YELLOW << " Delete folder after zipping? (y/n, default: y): " << RESET;
                std::getline(std::cin, deleteFolder);
                
                if (deleteFolder != "n") {
                    fs::remove_all(outDir);
                    std::cout << GREEN << "✓ Folder " << finalFolder << " deleted" << RESET << std::endl;
                } else {
                    std::cout << GREEN << "✓ Permanent folders are stored in: " << outDir << RESET << std::endl;
                }
            } else {
                std::cout << YELLOW << " Failed to create zip (zip not installed), files remain in folder: " << outDir << RESET << std::endl;
            }
        } else {
            std::cout << GREEN << " Done! The file is saved in: " << outDir << RESET << std::endl;
        }
        
    } catch (const std::exception& e) {
        std::cout << RED << "✗ Error: " << e.what() << RESET << std::endl;
    }
    
    curl_global_cleanup();
    return 0;
}