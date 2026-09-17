// admin-users · dipanggil dari aplikasi oleh akun Master untuk kelola akun.
// Aksi: create {username,name,role,password} · password {user_id,password} · active {user_id,active} · role {user_id,role}
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (b: unknown, s = 200) =>
  new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
const DOMAIN = "upscale.local"; // username → email internal (tidak dipakai untuk kirim email)

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const url = Deno.env.get("SUPABASE_URL")!;
  const anon = Deno.env.get("SUPABASE_ANON_KEY")!;
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const auth = req.headers.get("Authorization") ?? "";
  // 1. siapa pemanggilnya?
  const caller = createClient(url, anon, { global: { headers: { Authorization: auth } } });
  const { data: me } = await caller.auth.getUser();
  if (!me?.user) return json({ error: "Belum masuk" }, 401);
  const { data: prof } = await caller.from("profiles").select("role,active").eq("id", me.user.id).single();
  if (!prof || prof.role !== "master" || !prof.active) return json({ error: "Hanya Master" }, 403);
  // 2. jalankan aksi dengan service role
  const admin = createClient(url, service);
  const body = await req.json().catch(() => ({}));
  const a = body.action;
  try {
    if (a === "create") {
      const username = String(body.username || "").trim().toLowerCase();
      if (!/^[a-z0-9._-]{3,}$/.test(username)) return json({ error: "Nama pengguna minimal 3 huruf kecil/angka" }, 400);
      if (!body.password || String(body.password).length < 6) return json({ error: "Kata sandi minimal 6 karakter" }, 400);
      const role = ["master", "finance", "accounting"].includes(body.role) ? body.role : "accounting";
      const { data, error } = await admin.auth.admin.createUser({
        email: `${username}@${DOMAIN}`, password: body.password, email_confirm: true,
        user_metadata: { username, name: body.name || username, role },
      });
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true, user_id: data.user.id });
    }
    if (a === "password") {
      const { error } = await admin.auth.admin.updateUserById(body.user_id, { password: body.password });
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }
    if (a === "active") {
      const { error } = await admin.from("profiles").update({ active: !!body.active }).eq("id", body.user_id);
      if (error) return json({ error: error.message }, 400);
      if (!body.active) await admin.auth.admin.signOut?.(body.user_id).catch(() => {});
      return json({ ok: true });
    }
    if (a === "role") {
      const role = ["master", "finance", "accounting"].includes(body.role) ? body.role : null;
      if (!role) return json({ error: "Peran tidak valid" }, 400);
      if (body.user_id === me.user.id) return json({ error: "Tidak bisa mengubah peran sendiri" }, 400);
      const { error } = await admin.from("profiles").update({ role }).eq("id", body.user_id);
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }
    if (a === "delete") {
      if (body.user_id === me.user.id) return json({ error: "Tidak bisa menghapus akun sendiri" }, 400);
      const { error } = await admin.auth.admin.deleteUser(body.user_id);
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }
    return json({ error: "Aksi tidak dikenal" }, 400);
  } catch (e) {
    return json({ error: String(e) }, 500);
  }
});
