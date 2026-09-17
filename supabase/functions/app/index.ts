// app · menyajikan index.html (hosting statis lewat Edge Function, repo GitHub tetap privat)
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import html from "./index.html" with { type: "text" };
Deno.serve(() => new Response(html, { headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-cache" } }));
