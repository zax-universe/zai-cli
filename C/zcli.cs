// Program.cs - Z.AI CLI C# Version

using System;
using System.Collections.Generic;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.IO.Compression;
using System.Threading.Tasks;

namespace ZAI_CLI
{
    class Program
    {
        // ANSI color codes
        const string CYAN = "\u001b[36m";
        const string GREEN = "\u001b[32m";
        const string YELLOW = "\u001b[33m";
        const string RED = "\u001b[31m";
        const string GRAY = "\u001b[90m";
        const string RESET = "\u001b[0m";
        
        static bool inCodeBlock = false;
        static StringBuilder fullText = new StringBuilder();
        
        class Model
        {
            public string Id { get; set; }
            public string Display { get; set; }
        }
        
        class File
        {
            public string Path { get; set; }
            public string Content { get; set; }
        }
        
        static Dictionary<string, Model> availableModels = new Dictionary<string, Model>
        {
            { "1", new Model { Id = "zai-org/GLM-5", Display = "GLM 5" } },
            { "2", new Model { Id = "zai-org/GLM-5.1", Display = "Z GLM 5.1" } }
        };
        
        static string Question(string prompt)
        {
            Console.Write(prompt);
            return Console.ReadLine();
        }
        
        static async Task<string> PostAsync(string host, string path, string data)
        {
            using var client = new HttpClient();
            var content = new StringContent(data, Encoding.UTF8, "application/json");
            var response = await client.PostAsync($"https://{host}{path}", content);
            return await response.Content.ReadAsStringAsync();
        }
        
        static async Task<List<File>> StreamWithFilterAsync(string host, string path, string data)
        {
            using var client = new HttpClient();
            using var request = new HttpRequestMessage(HttpMethod.Post, $"https://{host}{path}");
            request.Content = new StringContent(data, Encoding.UTF8, "application/json");
            
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead);
            using var stream = await response.Content.ReadAsStreamAsync();
            using var reader = new StreamReader(stream);
            
            var allFiles = new List<File>();
            
            while (!reader.EndOfStream)
            {
                var line = await reader.ReadLineAsync();
                if (string.IsNullOrWhiteSpace(line)) continue;
                
                try
                {
                    var json = JsonDocument.Parse(line);
                    var text = json.RootElement
                        .GetProperty("choices")[0]
                        .GetProperty("delta")
                        .GetProperty("content")
                        .GetString();
                    
                    if (!string.IsNullOrEmpty(text))
                    {
                        fullText.Append(text);
                        
                        // Character by character processing
                        for (int i = 0; i < text.Length; i++)
                        {
                            if (i + 2 < text.Length && text.Substring(i, 3) == "```")
                            {
                                inCodeBlock = !inCodeBlock;
                                i += 2;
                            }
                            else if (!inCodeBlock)
                            {
                                Console.Write(text[i]);
                            }
                        }
                    }
                }
                catch { }
            }
            
            // Extract files using regex
            var regex = new Regex(@"```\w*\{path=([^}]+)\}\n([\s\S]*?)```");
            var matches = regex.Matches(fullText.ToString());
            
            foreach (Match match in matches)
            {
                var filePath = match.Groups[1].Value;
                var content = match.Groups[2].Value.TrimEnd('`').Trim();
                allFiles.Add(new File { Path = filePath, Content = content });
                Console.WriteLine($"{CYAN} Make: {filePath}{RESET}");
            }
            
            return allFiles;
        }
        
        static void WriteFiles(List<File> files, string outDir)
        {
            foreach (var file in files)
            {
                var fullPath = Path.Combine(outDir, file.Path);
                Directory.CreateDirectory(Path.GetDirectoryName(fullPath));
                File.WriteAllText(fullPath, file.Content);
                Console.WriteLine($"{GREEN}✓ {file.Path}{RESET}");
            }
        }
        
        static Model SelectModel()
        {
            Console.WriteLine($"\n{CYAN} Select an AI model:{RESET}");
            Console.WriteLine("  1. GLM 5");
            Console.WriteLine("  2. Z GLM 5.1");
            var choice = Question($"{YELLOW} Select (1-2, default: 1): {RESET}");
            choice = string.IsNullOrWhiteSpace(choice) ? "1" : choice;
            return availableModels.GetValueOrDefault(choice, availableModels["1"]);
        }
        
        static async Task Main(string[] args)
        {
            Console.WriteLine($"\n{CYAN}╔════════════════════════════════════╗{RESET}");
            Console.WriteLine($"{CYAN}║                Z.AI CLI                       ║{RESET}");
            Console.WriteLine($"{CYAN}╚════════════════════════════════════╝{RESET}\n");
            
            var selectedModel = SelectModel();
            Console.WriteLine($"{GREEN}✓ Model: {selectedModel.Display}{RESET}\n");
            
            var prompt = Question($"{YELLOW}Prompt Input: {RESET}");
            if (string.IsNullOrWhiteSpace(prompt))
            {
                Console.WriteLine($"{RED}✗ Prompt cannot be empty!{RESET}");
                return;
            }
            
            var defaultFolder = prompt.ToLower().Replace(' ', '-');
            if (defaultFolder.Length > 30) defaultFolder = defaultFolder.Substring(0, 30);
            var folderName = Question($"{YELLOW} Destination folder name (default: {defaultFolder}): {RESET}");
            var finalFolder = string.IsNullOrWhiteSpace(folderName) ? defaultFolder : folderName;
            
            Console.WriteLine($"\n{CYAN} Select output mode:{RESET}");
            Console.WriteLine("  1. Save to folder (without zip)");
            Console.WriteLine("  2. Save to folder + zip");
            var mode = Question($"{YELLOW} Choose (1/2, default: 1): {RESET}");
            
            var isZip = mode == "2";
            var outDir = finalFolder;
            var zipPath = $"{finalFolder}.zip";
            
            Console.WriteLine($"\n{CYAN}Generating: {prompt}{RESET}\n");
            
            try
            {
                var chatData = $"{{\"prompt\":\"{prompt}\",\"model\":\"{selectedModel.Id}\",\"quality\":\"low\"}}";
                var response = await PostAsync("llamacoder.together.ai", "/api/create-chat", chatData);
                
                var json = JsonDocument.Parse(response);
                var lastMessageId = json.RootElement.GetProperty("lastMessageId").GetInt32();
                
                Console.WriteLine($"{GREEN}✓ Chat created{RESET}");
                Console.WriteLine($"{YELLOW} AI is responding...{RESET}\n");
                Console.WriteLine($"{GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{RESET}\n");
                
                var streamData = $"{{\"messageId\":{lastMessageId},\"model\":\"{selectedModel.Id}\"}}";
                var files = await StreamWithFilterAsync("llamacoder.together.ai", 
                    "/api/get-next-completion-stream-promise", streamData);
                
                Console.WriteLine($"\n{GRAY}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━{RESET}\n");
                
                if (files.Count == 0)
                {
                    Console.WriteLine($"{RED}✗ No files are generated{RESET}");
                    return;
                }
                
                Console.WriteLine($"{GREEN} Total {files.Count} file will be created{RESET}\n");
                
                var confirm = Question($"{YELLOW}Continue writing file? (y/n, default: y): {RESET}");
                if (confirm?.ToLower() == "n")
                {
                    Console.WriteLine($"{RED}✗ Canceled{RESET}");
                    return;
                }
                
                if (Directory.Exists(outDir))
                {
                    Console.WriteLine($"{YELLOW}Folder {finalFolder} already exists, it will be overwritten...{RESET}");
                    Directory.Delete(outDir, true);
                }
                
                Directory.CreateDirectory(outDir);
                
                Console.WriteLine($"\n{CYAN} Write files to disk...{RESET}\n");
                WriteFiles(files, outDir);
                
                Console.WriteLine($"\n{GREEN} Succeed! {files.Count} the file has been saved{RESET}");
                
                if (isZip)
                {
                    Console.WriteLine($"{CYAN} Create zip...{RESET}");
                    try
                    {
                        ZipFile.CreateFromDirectory(outDir, zipPath);
                        Console.WriteLine($"{GREEN}✓ Zip created successfully: {zipPath}{RESET}");
                        
                        var deleteFolder = Question($"{YELLOW} Delete folder after zipping? (y/n, default: y): {RESET}");
                        if (deleteFolder?.ToLower() != "n")
                        {
                            Directory.Delete(outDir, true);
                            Console.WriteLine($"{GREEN}✓ Folder {finalFolder} deleted{RESET}");
                        }
                        else
                        {
                            Console.WriteLine($"{GREEN}✓ Permanent folders are stored in: {outDir}{RESET}");
                        }
                    }
                    catch
                    {
                        Console.WriteLine($"{YELLOW} Failed to create zip, files remain in folder: {outDir}{RESET}");
                    }
                }
                else
                {
                    Console.WriteLine($"{GREEN} Done! The file is saved in: {outDir}{RESET}");
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"{RED}✗ Error: {ex.Message}{RESET}");
            }
        }
    }
}