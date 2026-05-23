// ZCLI.java - Z.AI CLI Java Version

import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.file.*;
import java.util.*;
import java.util.regex.*;
import java.util.zip.*;

public class ZCLI {
    // ANSI color codes
    private static final String CYAN = "\033[36m";
    private static final String GREEN = "\033[32m";
    private static final String YELLOW = "\033[33m";
    private static final String RED = "\033[31m";
    private static final String GRAY = "\033[90m";
    private static final String RESET = "\033[0m";
    
    private static boolean inCodeBlock = false;
    private static StringBuilder fullText = new StringBuilder();
    
    private static class Model {
        String id;
        String display;
        Model(String id, String display) {
            this.id = id;
            this.display = display;
        }
    }
    
    private static class File {
        String path;
        String content;
        File(String path, String content) {
            this.path = path;
            this.content = content;
        }
    }
    
    private static Map<String, Model> availableModels = new HashMap<>();
    static {
        availableModels.put("1", new Model("zai-org/GLM-5", "GLM 5"));
        availableModels.put("2", new Model("zai-org/GLM-5.1", "Z GLM 5.1"));
    }
    
    private static String question(String prompt) throws IOException {
        System.out.print(prompt);
        BufferedReader reader = new BufferedReader(new InputStreamReader(System.in));
        return reader.readLine();
    }
    
    private static String post(String host, String path, String data) throws IOException {
        URL url = new URL("https://" + host + path);
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        conn.setRequestMethod("POST");
        conn.setRequestProperty("Content-Type", "application/json");
        conn.setDoOutput(true);
        
        try (OutputStream os = conn.getOutputStream()) {
            os.write(data.getBytes());
            os.flush();
        }
        
        try (BufferedReader br = new BufferedReader(new InputStreamReader(conn.getInputStream()))) {
            StringBuilder response = new StringBuilder();
            String line;
            while ((line = br.readLine()) != null) {
                response.append(line);
            }
            return response.toString();
        }
    }
    
    private static List<File> streamWithFilter(String host, String path, String data) throws IOException {
        URL url = new URL("https://" + host + path);
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        conn.setRequestMethod("POST");
        conn.setRequestProperty("Content-Type", "application/json");
        conn.setDoOutput(true);
        conn.setChunkedStreamingMode(0);
        
        try (OutputStream os = conn.getOutputStream()) {
            os.write(data.getBytes());
            os.flush();
        }
        
        List<File> allFiles = new ArrayList<>();
        
        try (BufferedReader br = new BufferedReader(new InputStreamReader(conn.getInputStream()))) {
            String line;
            while ((line = br.readLine()) != null) {
                if (line.trim().isEmpty()) continue;
                
                // Parse JSON line
                if (line.contains("\"choices\"")) {
                    String text = extractContentFromJson(line);
                    if (text != null && !text.isEmpty()) {
                        fullText.append(text);
                        
                        // Character by character processing
                        for (int i = 0; i < text.length(); i++) {
                            if (i + 2 < text.length() && text.substring(i, i+3).equals("```")) {
                                inCodeBlock = !inCodeBlock;
                                i += 2;
                            } else if (!inCodeBlock) {
                                System.out.print(text.charAt(i));
                            }
                        }
                    }
                }
            }
        }
        
        // Extract files using regex
        Pattern pattern = Pattern.compile("```\\w*\\{path=([^}]+)\\}\\n([\\s\\S]*?)```");
        Matcher matcher = pattern.matcher(fullText.toString());
        
        while (matcher.find()) {
            String filePath = matcher.group(1);
            String content = matcher.group(2).replaceAll("```$", "").trim();
            allFiles.add(new File(filePath, content));
            System.out.println(CYAN + " Make: " + filePath + RESET);
        }
        
        return allFiles;
    }
    
    private static String extractContentFromJson(String json) {
        try {
            // Simple extraction without full JSON parser
            Pattern pattern = Pattern.compile("\"content\":\"([^\"]*)\"");
            Matcher matcher = pattern.matcher(json);
            if (matcher.find()) {
                return matcher.group(1);
            }
        } catch (Exception e) {}
        return null;
    }
    
    private static void writeFiles(List<File> files, Path outDir) throws IOException {
        for (File file : files) {
            Path fullPath = outDir.resolve(file.path);
            Files.createDirectories(fullPath.getParent());
            Files.write(fullPath, file.content.getBytes());
            System.out.println(GREEN + "✓ " + file.path + RESET);
        }
    }
    
    private static Model selectModel() throws IOException {
        System.out.println("\n" + CYAN + " Select an AI model:" + RESET);
        System.out.println("  1. GLM 5");
        System.out.println("  2. Z GLM 5.1");
        String choice = question(YELLOW + " Select (1-2, default: 1): " + RESET);
        choice = choice.trim().isEmpty() ? "1" : choice;
        return availableModels.getOrDefault(choice, availableModels.get("1"));
    }
    
    public static void main(String[] args) throws IOException {
        System.out.println("\n" + CYAN + "╔════════════════════════════════════╗" + RESET);
        System.out.println(CYAN + "║                Z.AI CLI                       ║" + RESET);
        System.out.println(CYAN + "╚════════════════════════════════════╝" + RESET + "\n");
        
        Model selectedModel = selectModel();
        System.out.println(GREEN + "✓ Model: " + selectedModel.display + RESET + "\n");
        
        String prompt = question(YELLOW + "Prompt Input: " + RESET);
        if (prompt.trim().isEmpty()) {
            System.out.println(RED + "✗ Prompt cannot be empty!" + RESET);
            return;
        }
        
        String defaultFolder = prompt.toLowerCase().replaceAll("\\s+", "-");
        if (defaultFolder.length() > 30) defaultFolder = defaultFolder.substring(0, 30);
        String folderName = question(YELLOW + " Destination folder name (default: " + defaultFolder + "): " + RESET);
        String finalFolder = folderName.trim().isEmpty() ? defaultFolder : folderName;
        
        System.out.println("\n" + CYAN + " Select output mode:" + RESET);
        System.out.println("  1. Save to folder (without zip)");
        System.out.println("  2. Save to folder + zip");
        String mode = question(YELLOW + " Choose (1/2, default: 1): " + RESET);
        
        boolean isZip = mode.trim().equals("2");
        Path outDir = Paths.get(finalFolder);
        Path zipPath = Paths.get(finalFolder + ".zip");
        
        System.out.println("\n" + CYAN + "Generating: " + prompt + RESET + "\n");
        
        try {
            // Create chat
            String chatData = String.format(
                "{\"prompt\":\"%s\",\"model\":\"%s\",\"quality\":\"low\"}",
                prompt, selectedModel.id
            );
            String response = post("llamacoder.together.ai", "/api/create-chat", chatData);
            
            // Extract lastMessageId (simple parsing)
            String lastMessageId = extractValueFromJson(response, "lastMessageId");
            
            System.out.println(GREEN + "✓ Chat created" + RESET);
            System.out.println(YELLOW + " AI is responding..." + RESET + "\n");
            System.out.println(GRAY + "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" + RESET + "\n");
            
            String streamData = String.format(
                "{\"messageId\":%s,\"model\":\"%s\"}",
                lastMessageId, selectedModel.id
            );
            
            List<File> files = streamWithFilter("llamacoder.together.ai", 
                "/api/get-next-completion-stream-promise", streamData);
            
            System.out.println("\n" + GRAY + "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" + RESET + "\n");
            
            if (files.isEmpty()) {
                System.out.println(RED + "✗ No files are generated" + RESET);
                return;
            }
            
            System.out.println(GREEN + " Total " + files.size() + " file will be created" + RESET + "\n");
            
            String confirm = question(YELLOW + "Continue writing file? (y/n, default: y): " + RESET);
            if (confirm.trim().toLowerCase().equals("n")) {
                System.out.println(RED + "✗ Canceled" + RESET);
                return;
            }
            
            if (Files.exists(outDir)) {
                System.out.println(YELLOW + "Folder " + finalFolder + " already exists, it will be overwritten..." + RESET);
                deleteDirectory(outDir.toFile());
            }
            
            Files.createDirectories(outDir);
            
            System.out.println("\n" + CYAN + " Write files to disk..." + RESET + "\n");
            writeFiles(files, outDir);
            
            System.out.println("\n" + GREEN + " Succeed! " + files.size() + " the file has been saved" + RESET);
            
            if (isZip) {
                System.out.println(CYAN + " Create zip..." + RESET);
                try {
                    zipDirectory(outDir.toFile(), zipPath.toFile());
                    System.out.println(GREEN + "✓ Zip created successfully: " + zipPath + RESET);
                    
                    String deleteFolder = question(YELLOW + " Delete folder after zipping? (y/n, default: y): " + RESET);
                    if (!deleteFolder.trim().toLowerCase().equals("n")) {
                        deleteDirectory(outDir.toFile());
                        System.out.println(GREEN + "✓ Folder " + finalFolder + " deleted" + RESET);
                    } else {
                        System.out.println(GREEN + "✓ Permanent folders are stored in: " + outDir + RESET);
                    }
                } catch (Exception e) {
                    System.out.println(YELLOW + " Failed to create zip, files remain in folder: " + outDir + RESET);
                }
            } else {
                System.out.println(GREEN + " Done! The file is saved in: " + outDir + RESET);
            }
            
        } catch (Exception e) {
            System.out.println(RED + "✗ Error: " + e.getMessage() + RESET);
        }
    }
    
    private static String extractValueFromJson(String json, String key) {
        Pattern pattern = Pattern.compile("\"" + key + "\":(\\d+)");
        Matcher matcher = pattern.matcher(json);
        if (matcher.find()) {
            return matcher.group(1);
        }
        return "0";
    }
    
    private static void deleteDirectory(File dir) {
        if (dir.isDirectory()) {
            File[] children = dir.listFiles();
            if (children != null) {
                for (File child : children) {
                    deleteDirectory(child);
                }
            }
        }
        dir.delete();
    }
    
    private static void zipDirectory(File sourceDir, File zipFile) throws IOException {
        try (ZipOutputStream zos = new ZipOutputStream(new FileOutputStream(zipFile))) {
            Path sourcePath = sourceDir.toPath();
            Files.walk(sourcePath)
                .filter(path -> !Files.isDirectory(path))
                .forEach(path -> {
                    ZipEntry zipEntry = new ZipEntry(sourcePath.relativize(path).toString());
                    try {
                        zos.putNextEntry(zipEntry);
                        Files.copy(path, zos);
                        zos.closeEntry();
                    } catch (IOException e) {
                        e.printStackTrace();
                    }
                });
        }
    }
}