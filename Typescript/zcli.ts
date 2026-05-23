#!/usr/bin/env node
// zcli.ts - Z.AI CLI TypeScript Version

import * as https from 'https';
import * as fs from 'fs';
import * as path from 'path';
import * as readline from 'readline';
import { execSync } from 'child_process';
import { fileURLToPath } from 'url';

const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
});

function question(query: string): Promise<string> {
    return new Promise(resolve => rl.question(query, resolve));
}

interface PostData {
    [key: string]: any;
}

interface ChatResponse {
    chatId: string;
    lastMessageId: number;
}

interface StreamResponse {
    choices?: Array<{
        delta?: {
            content?: string;
        };
    }>;
}

interface File {
    path: string;
    content: string;
}

interface Progress {
    onFileDetected?: (filePath: string) => void;
}

async function post(host: string, p: string, data: PostData): Promise<any> {
    return new Promise((resolve, reject) => {
        const body = JSON.stringify(data);
        const req = https.request({
            hostname: host,
            path: p,
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "Content-Length": Buffer.byteLength(body)
            }
        }, (res) => {
            let raw = "";
            res.on("data", (c) => (raw += c));
            res.on("end", () => resolve(JSON.parse(raw)));
        });
        req.on("error", reject);
        req.write(body);
        req.end();
    });
}

async function streamWithFilter(host: string, p: string, data: PostData, onProgress?: Progress): Promise<File[]> {
    return new Promise((resolve, reject) => {
        const body = JSON.stringify(data);
        let fullText = "";
        let inCodeBlock = false;
        const allFiles: File[] = [];
        
        const req = https.request({
            hostname: host,
            path: p,
            method: "POST",
            headers: {
                "Content-Type": "application/json",
                "Content-Length": Buffer.byteLength(body)
            }
        }, (res) => {
            res.on("data", (chunk) => {
                const chunkStr = chunk.toString();
                const lines = chunkStr.split("\n");
                
                for (const line of lines) {
                    try {
                        const j: StreamResponse = JSON.parse(line);
                        const text = j.choices?.[0]?.delta?.content;
                        if (text) {
                            fullText += text;
                            
                            // Character by character process
                            for (let i = 0; i < text.length; i++) {
                                if (text[i] === '`' && text.substring(i, i+3) === '```') {
                                    inCodeBlock = !inCodeBlock;
                                    i += 2;
                                } 
                                else if (!inCodeBlock) {
                                    process.stdout.write(text[i]);
                                }
                            }
                        }
                    } catch {}
                }
            });
            
            res.on("end", () => {
                const regex = /```\w*\{path=([^}]+)\}\n([\s\S]*?)```/g;
                let match;
                while ((match = regex.exec(fullText)) !== null) {
                    allFiles.push({ path: match[1], content: match[2] });
                    if (onProgress && onProgress.onFileDetected) {
                        onProgress.onFileDetected(match[1]);
                    }
                }
                resolve(allFiles);
            });
        });
        req.on("error", reject);
        req.write(body);
        req.end();
    });
}

function writeFiles(files: File[], outDir: string): void {
    for (const file of files) {
        const full = path.join(outDir, file.path);
        fs.mkdirSync(path.dirname(full), { recursive: true });
        fs.writeFileSync(full, file.content);
        console.log(`\x1b[32m✓ ${file.path}\x1b[0m`);
    }
}

interface Model {
    id: string;
    name: string;
    display: string;
}

const AVAILABLE_MODELS: Record<string, Model> = {
    "1": { id: "zai-org/GLM-5", name: "Z GLM 5", display: "GLM 5" },
    "2": { id: "zai-org/GLM-5.1", name: "GLM 5.1", display: "Z GLM 5.1" }
};

async function selectModel(): Promise<Model> {
    console.log("\n\x1b[36m Select an AI model:\x1b[0m");
    for (const [key, model] of Object.entries(AVAILABLE_MODELS)) {
        console.log(`  ${key}. ${model.display}`);
    }
    const choice = await question("\x1b[33m Select (1-2, default: 1): \x1b[0m");
    const selectedKey = choice.trim() || "1";
    return AVAILABLE_MODELS[selectedKey] || AVAILABLE_MODELS["1"];
}

async function main(): Promise<void> {
    console.log("\n\x1b[36m╔════════════════════════════════════╗\x1b[0m");
    console.log("\x1b[36m║                Z.AI CLI                       ║\x1b[0m");
    console.log("\x1b[36m╚════════════════════════════════════╝\x1b[0m\n");
    
    const selectedModel = await selectModel();
    console.log(`\x1b[32m✓ Model: ${selectedModel.display}\x1b[0m\n`);
    
    const prompt = await question("\x1b[33mPrompt Input: \x1b[0m");
    if (!prompt.trim()) {
        console.log("\x1b[31m✗ Prompt cannot be empty!\x1b[0m");
        rl.close();
        return;
    }
    
    const defaultFolder = prompt.replace(/\s+/g, "-").toLowerCase().slice(0, 30);
    const folderName = await question(`\x1b[33m Destination folder name (default: ${defaultFolder}): \x1b[0m`);
    const finalFolder = folderName.trim() || defaultFolder;
    
    console.log("\n\x1b[36m Select output mode:\x1b[0m");
    console.log("  1. Save to folder (without zip)");
    console.log("  2. Save to folder + zip");
    const mode = await question("\x1b[33m Choose (1/2, default: 1): \x1b[0m");
    
    const isZip = mode.trim() === "2";
    const outDir = path.join(process.cwd(), finalFolder);
    const zipPath = `${outDir}.zip`;
    
    console.log(`\n\x1b[36mGenerating: ${prompt}\x1b[0m\n`);
    
    try {
        const response = await post("llamacoder.together.ai", "/api/create-chat", {
            prompt,
            model: selectedModel.id,
            quality: "low",
        }) as ChatResponse;
        
        const { chatId, lastMessageId } = response;
        
        console.log(`\x1b[32m✓ Chat created\x1b[0m`);
        console.log(`\x1b[33m AI is responding...\x1b[0m\n`);
        console.log("\x1b[90m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\x1b[0m\n");
        
        const progress: Progress = {
            onFileDetected: (filePath: string) => {
                console.log(`\x1b[36m Make: ${filePath}\x1b[0m`);
            }
        };
        
        const files = await streamWithFilter(
            "llamacoder.together.ai",
            "/api/get-next-completion-stream-promise",
            { messageId: lastMessageId, model: selectedModel.id },
            progress
        );
        
        console.log("\n\x1b[90m━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\x1b[0m\n");
        
        if (files.length === 0) {
            console.log(`\x1b[31m✗ No files are generated\x1b[0m`);
            rl.close();
            return;
        }
        
        console.log(`\x1b[32m Total ${files.length} file will be created\x1b[0m\n`);
        
        const confirm = await question("\x1b[33mContinue writing file? (y/n, default: y): \x1b[0m");
        if (confirm.trim().toLowerCase() === "n") {
            console.log("\x1b[31m✗ Canceled\x1b[0m");
            rl.close();
            return;
        }
        
        if (fs.existsSync(outDir)) {
            console.log(`\x1b[33mFolder ${finalFolder} already exists, it will be overwritten...\x1b[0m`);
            fs.rmSync(outDir, { recursive: true, force: true });
        }
        
        fs.mkdirSync(outDir, { recursive: true });
        
        console.log(`\n\x1b[36m Write files to disk...\x1b[0m\n`);
        writeFiles(files, outDir);
        
        console.log(`\n\x1b[32m Succeed! ${files.length} the file has been saved\x1b[0m`);
        
        if (isZip) {
            console.log(`\x1b[36m Create zip...\x1b[0m`);
            try {
                execSync(`zip -r "${zipPath}" "${path.basename(outDir)}"`, { cwd: process.cwd(), stdio: 'pipe' });
                console.log(`\x1b[32m✓ Zip created successfully: ${zipPath}\x1b[0m`);
                
                const deleteFolder = await question("\x1b[33m Delete folder after zipping? (y/n, default: y): \x1b[0m");
                if (deleteFolder.trim().toLowerCase() !== "n") {
                    fs.rmSync(outDir, { recursive: true, force: true });
                    console.log(`\x1b[32m✓ Folder ${finalFolder} deleted\x1b[0m`);
                } else {
                    console.log(`\x1b[32m✓ Permanent folders are stored in: ${outDir}\x1b[0m`);
                }
            } catch {
                console.log(`\x1b[33m Failed to create zip (zip not installed), files remain in folder: ${outDir}\x1b[0m`);
            }
        } else {
            console.log(`\x1b[32m Done! The file is saved in: ${outDir}\x1b[0m`);
        }
        
    } catch (error: any) {
        console.log(`\x1b[31m✗ Error: ${error.message}\x1b[0m`);
    }
    
    rl.close();
}

main();