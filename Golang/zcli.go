package main

import (
    "bufio"
    "bytes"
    "encoding/json"
    "fmt"
    "io"
    "net/http"
    "os"
    "os/exec"
    "path/filepath"
    "regexp"
    "strings"
)

// ANSI colors
const (
    colorCyan   = "\033[36m"
    colorGreen  = "\033[32m"
    colorYellow = "\033[33m"
    colorRed    = "\033[31m"
    colorGray   = "\033[90m"
    colorReset  = "\033[0m"
)

type Model struct {
    ID      string
    Name    string
    Display string
}

var availableModels = map[string]Model{
    "1": {ID: "zai-org/GLM-5", Name: "Z GLM 5", Display: "GLM 5"},
    "2": {ID: "zai-org/GLM-5.1", Name: "GLM 5.1", Display: "Z GLM 5.1"},
}

type CreateChatRequest struct {
    Prompt  string `json:"prompt"`
    Model   string `json:"model"`
    Quality string `json:"quality"`
}

type CreateChatResponse struct {
    ChatID        string `json:"chatId"`
    LastMessageID int    `json:"lastMessageId"`
}

type StreamRequest struct {
    MessageID int    `json:"messageId"`
    Model     string `json:"model"`
}

type StreamResponse struct {
    Choices []struct {
        Delta struct {
            Content string `json:"content"`
        } `json:"delta"`
    } `json:"choices"`
}

type File struct {
    Path    string
    Content string
}

func question(prompt string) string {
    fmt.Print(prompt)
    scanner := bufio.NewScanner(os.Stdin)
    scanner.Scan()
    return scanner.Text()
}

func post(host, path string, data interface{}) ([]byte, error) {
    body, err := json.Marshal(data)
    if err != nil {
        return nil, err
    }
    
    url := fmt.Sprintf("https://%s%s", host, path)
    req, err := http.NewRequest("POST", url, bytes.NewBuffer(body))
    if err != nil {
        return nil, err
    }
    
    req.Header.Set("Content-Type", "application/json")
    
    client := &http.Client{}
    resp, err := client.Do(req)
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()
    
    return io.ReadAll(resp.Body)
}

func streamWithFilter(host, path string, data interface{}, onFileDetected func(string)) ([]File, error) {
    body, err := json.Marshal(data)
    if err != nil {
        return nil, err
    }
    
    url := fmt.Sprintf("https://%s%s", host, path)
    req, err := http.NewRequest("POST", url, bytes.NewBuffer(body))
    if err != nil {
        return nil, err
    }
    
    req.Header.Set("Content-Type", "application/json")
    
    client := &http.Client{}
    resp, err := client.Do(req)
    if err != nil {
        return nil, err
    }
    defer resp.Body.Close()
    
    fullText := ""
    inCodeBlock := false
    var allFiles []File
    
    scanner := bufio.NewScanner(resp.Body)
    for scanner.Scan() {
        line := scanner.Text()
        if line == "" {
            continue
        }
        
        var sr StreamResponse
        if err := json.Unmarshal([]byte(line), &sr); err == nil {
            if len(sr.Choices) > 0 && sr.Choices[0].Delta.Content != "" {
                text := sr.Choices[0].Delta.Content
                fullText += text
                
                // Character by character processing
                for i := 0; i < len(text); i++ {
                    if i+2 < len(text) && text[i:i+3] == "```" {
                        inCodeBlock = !inCodeBlock
                        i += 2
                    } else if !inCodeBlock {
                        fmt.Print(string(text[i]))
                    }
                }
            }
        }
    }
    
    // Extract files using regex
    re := regexp.MustCompile("```\\w*\\{path=([^}]+)\\}\\n([\\s\\S]*?)```")
    matches := re.FindAllStringSubmatch(fullText, -1)
    
    for _, match := range matches {
        if len(match) >= 3 {
            file := File{Path: match[1], Content: match[2]}
            allFiles = append(allFiles, file)
            if onFileDetected != nil {
                onFileDetected(file.Path)
            }
        }
    }
    
    return allFiles, nil
}

func writeFiles(files []File, outDir string) {
    for _, file := range files {
        fullPath := filepath.Join(outDir, file.Path)
        os.MkdirAll(filepath.Dir(fullPath), 0755)
        os.WriteFile(fullPath, []byte(file.Content), 0644)
        fmt.Printf("%s✓ %s%s\n", colorGreen, file.Path, colorReset)
    }
}

func selectModel() Model {
    fmt.Printf("\n%s Select an AI model:%s\n", colorCyan, colorReset)
    fmt.Println("  1. GLM 5")
    fmt.Println("  2. Z GLM 5.1")
    
    choice := question(fmt.Sprintf("%s Select (1-2, default: 1): %s", colorYellow, colorReset))
    if choice == "" {
        choice = "1"
    }
    
    if model, ok := availableModels[choice]; ok {
        return model
    }
    return availableModels["1"]
}

func main() {
    fmt.Printf("\n%s╔════════════════════════════════════╗%s\n", colorCyan, colorReset)
    fmt.Printf("%s║                Z.AI CLI                       ║%s\n", colorCyan, colorReset)
    fmt.Printf("%s╚════════════════════════════════════╝%s\n\n", colorCyan, colorReset)
    
    selectedModel := selectModel()
    fmt.Printf("%s✓ Model: %s%s\n\n", colorGreen, selectedModel.Display, colorReset)
    
    prompt := question(fmt.Sprintf("%sPrompt Input: %s", colorYellow, colorReset))
    if strings.TrimSpace(prompt) == "" {
        fmt.Printf("%s✗ Prompt cannot be empty!%s\n", colorRed, colorReset)
        return
    }
    
    defaultFolder := strings.ReplaceAll(strings.ToLower(prompt), " ", "-")
    if len(defaultFolder) > 30 {
        defaultFolder = defaultFolder[:30]
    }
    
    folderName := question(fmt.Sprintf("%s Destination folder name (default: %s): %s", colorYellow, defaultFolder, colorReset))
    finalFolder := folderName
    if finalFolder == "" {
        finalFolder = defaultFolder
    }
    
    fmt.Printf("\n%s Select output mode:%s\n", colorCyan, colorReset)
    fmt.Println("  1. Save to folder (without zip)")
    fmt.Println("  2. Save to folder + zip")
    
    mode := question(fmt.Sprintf("%s Choose (1/2, default: 1): %s", colorYellow, colorReset))
    isZip := mode == "2"
    
    outDir := finalFolder
    zipPath := finalFolder + ".zip"
    
    fmt.Printf("\n%sGenerating: %s%s\n\n", colorCyan, prompt, colorReset)
    
    // Create chat
    chatReq := CreateChatRequest{
        Prompt:  prompt,
        Model:   selectedModel.ID,
        Quality: "low",
    }
    
    resp, err := post("llamacoder.together.ai", "/api/create-chat", chatReq)
    if err != nil {
        fmt.Printf("%s✗ Error: %v%s\n", colorRed, err, colorReset)
        return
    }
    
    var chatResp CreateChatResponse
    json.Unmarshal(resp, &chatResp)
    
    fmt.Printf("%s✓ Chat created%s\n", colorGreen, colorReset)
    fmt.Printf("%s AI is responding...%s\n\n", colorYellow, colorReset)
    fmt.Printf("%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n\n", colorGray, colorReset)
    
    streamReq := StreamRequest{
        MessageID: chatResp.LastMessageID,
        Model:     selectedModel.ID,
    }
    
    files, err := streamWithFilter("llamacoder.together.ai", "/api/get-next-completion-stream-promise", streamReq, func(filePath string) {
        fmt.Printf("%s Make: %s%s\n", colorCyan, filePath, colorReset)
    })
    
    if err != nil {
        fmt.Printf("%s✗ Error: %v%s\n", colorRed, err, colorReset)
        return
    }
    
    fmt.Printf("\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n\n", colorGray, colorReset)
    
    if len(files) == 0 {
        fmt.Printf("%s✗ No files are generated%s\n", colorRed, colorReset)
        return
    }
    
    fmt.Printf("%s Total %d file will be created%s\n\n", colorGreen, len(files), colorReset)
    
    confirm := question(fmt.Sprintf("%sContinue writing file? (y/n, default: y): %s", colorYellow, colorReset))
    if strings.ToLower(strings.TrimSpace(confirm)) == "n" {
        fmt.Printf("%s✗ Canceled%s\n", colorRed, colorReset)
        return
    }
    
    // Check if directory exists
    if _, err := os.Stat(outDir); err == nil {
        fmt.Printf("%sFolder %s already exists, it will be overwritten...%s\n", colorYellow, finalFolder, colorReset)
        os.RemoveAll(outDir)
    }
    
    os.MkdirAll(outDir, 0755)
    
    fmt.Printf("\n%s Write files to disk...%s\n\n", colorCyan, colorReset)
    writeFiles(files, outDir)
    
    fmt.Printf("\n%s Succeed! %d the file has been saved%s\n", colorGreen, len(files), colorReset)
    
    if isZip {
        fmt.Printf("%s Create zip...%s\n", colorCyan, colorReset)
        cmd := exec.Command("zip", "-r", zipPath, filepath.Base(outDir))
        cmd.Dir = filepath.Dir(outDir)
        if err := cmd.Run(); err == nil {
            fmt.Printf("%s✓ Zip created successfully: %s%s\n", colorGreen, zipPath, colorReset)
            
            deleteFolder := question(fmt.Sprintf("%s Delete folder after zipping? (y/n, default: y): %s", colorYellow, colorReset))
            if strings.ToLower(strings.TrimSpace(deleteFolder)) != "n" {
                os.RemoveAll(outDir)
                fmt.Printf("%s✓ Folder %s deleted%s\n", colorGreen, finalFolder, colorReset)
            } else {
                fmt.Printf("%s✓ Permanent folders are stored in: %s%s\n", colorGreen, outDir, colorReset)
            }
        } else {
            fmt.Printf("%s Failed to create zip (zip not installed), files remain in folder: %s%s\n", colorYellow, outDir, colorReset)
        }
    } else { 
        fmt.Printf("%s Done! The file is saved in: %s%s\n", colorGreen, outDir, colorReset)
    }
}