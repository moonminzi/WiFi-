// QR 파일 공유 Worker
//
//   GET    /ping                        업로드 비밀번호 확인 (앱 설정의 "연결 테스트")
//   PUT    /upload?name=..&hours=..     파일 올리기 → { id, url, expiresAt, size }
//   GET    /f/:id                       받는 사람이 보는 안내 페이지
//   GET    /f/:id/download[?inline=1]   파일 내려받기
//   DELETE /f/:id                       공유 중지
//
// KV 값 하나는 최대 25MiB라서 20MiB 조각으로 나눠 저장한다. 모든 키에 만료 시간을 걸어 두므로 따로 청소할 필요가 없다.

const CHUNK_SIZE = 20 * 1024 * 1024;
const MAX_UPLOAD = 100 * 1024 * 1024; // Workers 무료 플랜의 요청 본문 한도
const DEFAULT_HOURS = 24;
const MAX_HOURS = 24 * 7;
const ID_PATTERN = /^[A-Za-z0-9_-]{8,32}$/;
const INLINE_TYPES = /^(image\/(png|jpeg|gif|webp|heic|heif)|video\/(mp4|quicktime)|application\/pdf|text\/plain)$/;

export default {
	async fetch(request, env, ctx) {
		const url = new URL(request.url);
		const parts = url.pathname.split('/').filter(Boolean);

		try {
			if (parts[0] === 'ping' && request.method === 'GET') {
				return (await authorized(request, env)) ? json({ ok: true }) : unauthorized();
			}
			if (parts[0] === 'upload' && parts.length === 1 && request.method === 'PUT') {
				return await upload(request, env, url);
			}
			if (parts[0] === 'f' && ID_PATTERN.test(parts[1] ?? '')) {
				const id = parts[1];
				if (parts.length === 2 && request.method === 'GET') return await landing(env, url, id);
				if (parts.length === 2 && request.method === 'DELETE') return await remove(request, env, id);
				if (parts.length === 3 && parts[2] === 'download' && (request.method === 'GET' || request.method === 'HEAD')) {
					return await download(request, env, ctx, url, id);
				}
			}
			return text('찾을 수 없는 주소예요.', 404);
		} catch (err) {
			console.error(err);
			return json({ error: '서버 오류가 났어요.' }, 500);
		}
	},
};

// MARK: - 업로드

async function upload(request, env, url) {
	if (!(await authorized(request, env))) return unauthorized();

	const length = Number(request.headers.get('Content-Length'));
	if (!request.body || !Number.isFinite(length) || length <= 0) {
		return json({ error: '빈 파일은 올릴 수 없어요.' }, 411);
	}
	if (length > MAX_UPLOAD) return json({ error: '100MB까지만 올릴 수 있어요.' }, 413);

	const name = sanitizeName(url.searchParams.get('name'));
	const hours = clamp(parseInt(url.searchParams.get('hours') ?? '', 10) || DEFAULT_HOURS, 1, MAX_HOURS);
	const ttl = hours * 3600;
	const expiresAt = Date.now() + ttl * 1000;
	const type = (request.headers.get('Content-Type') || 'application/octet-stream').split(';')[0].trim().toLowerCase();
	const id = randomId();

	let size = 0;
	let chunks = 0;
	for await (const chunk of chunked(request.body, CHUNK_SIZE)) {
		size += chunk.byteLength;
		if (size > MAX_UPLOAD) {
			await deleteFile(env, id, chunks);
			return json({ error: '100MB까지만 올릴 수 있어요.' }, 413);
		}
		await env.FILES.put(chunkKey(id, chunks), chunk, { expirationTtl: ttl });
		chunks += 1;
	}
	if (size === 0) return json({ error: '빈 파일은 올릴 수 없어요.' }, 411);

	const meta = { name, type, size, chunks, expiresAt };
	await env.FILES.put(metaKey(id), JSON.stringify(meta), { expirationTtl: ttl });

	return json({ id, url: `${url.origin}/f/${id}`, expiresAt: new Date(expiresAt).toISOString(), size }, 201);
}

/** 스트림을 정확히 `size` 바이트짜리 조각으로 잘라 내보낸다(마지막 조각은 더 작을 수 있음). */
async function* chunked(stream, size) {
	const reader = stream.getReader();
	let parts = [];
	let buffered = 0;
	for (;;) {
		const { done, value } = await reader.read();
		if (value) {
			let offset = 0;
			while (offset < value.byteLength) {
				const take = Math.min(size - buffered, value.byteLength - offset);
				parts.push(value.subarray(offset, offset + take));
				buffered += take;
				offset += take;
				if (buffered === size) {
					yield concat(parts, buffered);
					parts = [];
					buffered = 0;
				}
			}
		}
		if (done) break;
	}
	if (buffered > 0) yield concat(parts, buffered);
}

function concat(parts, total) {
	if (parts.length === 1) return parts[0].slice();
	const out = new Uint8Array(total);
	let offset = 0;
	for (const part of parts) {
		out.set(part, offset);
		offset += part.byteLength;
	}
	return out;
}

// MARK: - 내려받기

async function download(request, env, ctx, url, id) {
	const meta = await readMeta(env, id);
	if (!meta) return gone();

	const inline = url.searchParams.get('inline') === '1' && INLINE_TYPES.test(meta.type);
	const headers = new Headers({
		'Content-Type': meta.type,
		'Content-Length': String(meta.size),
		'Content-Disposition': contentDisposition(inline ? 'inline' : 'attachment', meta.name),
		'Cache-Control': 'private, no-store',
		'X-Content-Type-Options': 'nosniff',
	});
	if (request.method === 'HEAD') return new Response(null, { headers });

	if (meta.chunks === 1) {
		const body = await env.FILES.get(chunkKey(id, 0), { type: 'stream' });
		if (!body) return gone();
		return new Response(body, { headers });
	}

	// 여러 조각을 차례로 이어 붙여 보낸다. 길이를 알려 줘야 받는 쪽에 진행률이 보인다.
	const { readable, writable } = new FixedLengthStream(meta.size);
	ctx.waitUntil(
		(async () => {
			for (let i = 0; i < meta.chunks; i++) {
				const part = await env.FILES.get(chunkKey(id, i), { type: 'stream' });
				if (!part) {
					await writable.abort(new Error(`missing chunk ${i}`));
					return;
				}
				await part.pipeTo(writable, { preventClose: true });
			}
			await writable.close();
		})().catch((err) => console.error(err)),
	);
	return new Response(readable, { headers });
}

async function landing(env, url, id) {
	const meta = await readMeta(env, id);
	if (!meta) return gone();

	const downloadURL = `${url.origin}/f/${id}/download`;
	const preview = /^image\//.test(meta.type) && INLINE_TYPES.test(meta.type)
		? `<img src="${downloadURL}?inline=1" alt="">`
		: '';
	const expires = new Date(meta.expiresAt).toLocaleString('ko-KR', {
		timeZone: 'Asia/Seoul', month: 'long', day: 'numeric', hour: 'numeric', minute: '2-digit',
	});

	return new Response(
		`<!doctype html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>${escapeHTML(meta.name)}</title>
<style>
  :root { color-scheme: light dark; --bg: #f5f5f7; --card: #fff; --text: #1d1d1f; --muted: #6e6e73; --accent: #0071e3; }
  @media (prefers-color-scheme: dark) { :root { --bg: #000; --card: #1c1c1e; --text: #f5f5f7; --muted: #98989d; --accent: #2997ff; } }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--bg); color: var(--text);
         font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo", "Noto Sans KR", sans-serif; }
  main { width: min(420px, calc(100% - 32px)); background: var(--card); border-radius: 20px; padding: 28px 24px; box-sizing: border-box; text-align: center; }
  img { max-width: 100%; max-height: 50vh; border-radius: 12px; margin-bottom: 16px; }
  h1 { font-size: 18px; margin: 0 0 4px; word-break: break-all; }
  p { margin: 0; color: var(--muted); font-size: 14px; }
  a.button { display: block; margin-top: 20px; padding: 14px; border-radius: 12px; background: var(--accent); color: #fff; text-decoration: none; font-weight: 600; }
</style>
</head>
<body>
<main>
  ${preview}
  <h1>${escapeHTML(meta.name)}</h1>
  <p>${formatSize(meta.size)} · ${escapeHTML(expires)}까지</p>
  <a class="button" href="${downloadURL}">내려받기</a>
</main>
</body>
</html>`,
		{ headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'private, no-store' } },
	);
}

// MARK: - 삭제

async function remove(request, env, id) {
	if (!(await authorized(request, env))) return unauthorized();
	const meta = await readMeta(env, id);
	await deleteFile(env, id, meta?.chunks ?? 0);
	return json({ ok: true });
}

async function deleteFile(env, id, chunks) {
	const keys = [metaKey(id)];
	for (let i = 0; i < chunks; i++) keys.push(chunkKey(id, i));
	await Promise.all(keys.map((key) => env.FILES.delete(key)));
}

// MARK: - 도우미

const metaKey = (id) => `meta:${id}`;
const chunkKey = (id, n) => `chunk:${id}:${n}`;

async function readMeta(env, id) {
	const meta = await env.FILES.get(metaKey(id), { type: 'json' });
	if (!meta || Date.now() > meta.expiresAt) return null;
	return meta;
}

async function authorized(request, env) {
	if (!env.UPLOAD_TOKEN) return false;
	const given = new TextEncoder().encode(request.headers.get('Authorization') ?? '');
	const expected = new TextEncoder().encode(`Bearer ${env.UPLOAD_TOKEN}`);
	if (given.byteLength !== expected.byteLength) return false;
	return crypto.subtle.timingSafeEqual(given, expected);
}

function randomId() {
	const bytes = crypto.getRandomValues(new Uint8Array(9));
	return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_');
}

function sanitizeName(raw) {
	const name = (raw ?? '').replace(/[\u0000-\u001f\u007f/\\]/g, '_').trim().slice(0, 200);
	return name || 'file';
}

function contentDisposition(kind, name) {
	const ascii = name.replace(/[^\x20-\x7e]/g, '_').replace(/["\\]/g, '_');
	const encoded = encodeURIComponent(name).replace(/['()*]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase());
	return `${kind}; filename="${ascii}"; filename*=UTF-8''${encoded}`;
}

function escapeHTML(s) {
	return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
}

function formatSize(bytes) {
	if (bytes < 1024) return `${bytes}B`;
	if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}KB`;
	return `${(bytes / 1024 / 1024).toFixed(1)}MB`;
}

const clamp = (n, lo, hi) => Math.min(Math.max(n, lo), hi);

function json(body, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' },
	});
}

function text(body, status) {
	return new Response(body, { status, headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
}

const unauthorized = () => json({ error: '업로드 비밀번호가 맞지 않아요.' }, 401);
const gone = () => text('파일이 없거나 공유 기간이 끝났어요.', 404);
