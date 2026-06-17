// Receives anonymous normalized merchant keyword lists from devices.
// Admin reviews in the admin panel and promotes to merchant_keywords table.
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts'

serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('Method Not Allowed', { status: 405 })
  }
  const body = await req.json().catch(() => null)
  if (!body?.keywords || !Array.isArray(body.keywords)) {
    return new Response('Bad Request', { status: 400 })
  }
  // TODO: insert into merchant_keywords_pending for admin review
  return new Response(JSON.stringify({ received: body.keywords.length }), {
    headers: { 'Content-Type': 'application/json' },
    status: 200,
  })
})
