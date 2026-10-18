// bun scripts/keeper.ts   run one keeper pass locally (resolve/settle/unwind markets and wagers)
import { runKeeper } from "../functions/keeper";
console.log(JSON.stringify(await runKeeper(), null, 1));
process.exit(0);
