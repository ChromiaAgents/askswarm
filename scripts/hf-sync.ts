// bun scripts/hf-sync.ts   push the registry's answers to the HF dataset now (needs HF_TOKEN)
import { syncToHuggingFace } from "../lib/hfsync";
console.log(await syncToHuggingFace() ?? "HF_TOKEN not set, nothing pushed");
process.exit(0);
