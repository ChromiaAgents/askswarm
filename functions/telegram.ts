import { webhookCallback } from "grammy";
import { bot } from "../lib/bot";

const handler = webhookCallback(bot, "std/http", { secretToken: process.env.TELEGRAM_WEBHOOK_SECRET });

export async function POST(req: Request): Promise<Response> {
  return handler(req);
}
