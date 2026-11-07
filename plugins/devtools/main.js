// TabFlick 开发工具箱插件（官方）。不联网：输入一段文字，列出它能做的转换（编解码、时间戳、JSON、JWT、进制、颜色、网址参数、哈希、大写金额），回车拷贝结果。
// JavaScriptCore 里没有 btoa / TextEncoder：UTF-8 用 encodeURIComponent + unescape 转成字节串，Base64 自己写。

const LANG = (typeof tabflick !== "undefined" && tabflick.locale) || "en"
function t(zh, hant, en) {
  if (LANG === "zh") return zh
  if (LANG === "zh-Hant") return hant
  return en
}

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function utf8Bytes(text) {
  return unescape(encodeURIComponent(text))
}

/** 字节串 → 文字；不是合法的 UTF-8 抛错。 */
function fromUtf8Bytes(bytes) {
  return decodeURIComponent(escape(bytes))
}

function base64Encode(text) {
  const bytes = utf8Bytes(text)
  let out = ""
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes.charCodeAt(i), b = bytes.charCodeAt(i + 1), c = bytes.charCodeAt(i + 2)
    const n = (a << 16) | ((b || 0) << 8) | (c || 0)
    out += B64[(n >> 18) & 63] + B64[(n >> 12) & 63]
      + (i + 1 < bytes.length ? B64[(n >> 6) & 63] : "=") + (i + 2 < bytes.length ? B64[n & 63] : "=")
  }
  return out
}

/** Base64（也认 URL 安全的 - _、不带补位的 =）→ 文字；不是 Base64 或解出来不是 UTF-8 文字返回 null。 */
function base64Decode(text) {
  let s = String(text).trim().replace(/-/g, "+").replace(/_/g, "/")
  if (s.length < 4 || !/^[A-Za-z0-9+/]+={0,2}$/.test(s)) return null
  s = s.replace(/=+$/, "")
  if (s.length % 4 === 1) return null
  let bytes = ""
  for (let i = 0; i < s.length; i += 4) {
    const n = (B64.indexOf(s[i]) << 18) | (B64.indexOf(s[i + 1]) << 12)
      | ((i + 2 < s.length ? B64.indexOf(s[i + 2]) : 0) << 6) | (i + 3 < s.length ? B64.indexOf(s[i + 3]) : 0)
    bytes += String.fromCharCode((n >> 16) & 255)
    if (i + 2 < s.length) bytes += String.fromCharCode((n >> 8) & 255)
    if (i + 3 < s.length) bytes += String.fromCharCode(n & 255)
  }
  try {
    const decoded = fromUtf8Bytes(bytes)
    // 解出来一堆控制字符的不算（随便一个英文单词也可能「是」Base64）
    return /^[\P{C}\n\r\t]*$/u.test(decoded) && decoded.trim() ? decoded : null
  } catch (e) {
    return null
  }
}

// MARK: - 哈希（JSC 里没有 crypto，自己写；校验脚本拿 node 的 crypto 对答案）

const MD5_K = [
  0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
  0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
  0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa, 0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
  0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
  0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
  0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
  0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
  0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1, 0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
]
const MD5_S = [7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21]
const SHA256_K = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]

const rotl = (x, n) => (x << n) | (x >>> (32 - n))
const rotr = (x, n) => (x >>> n) | (x << (32 - n))
const beHex = (v) => (v >>> 0).toString(16).padStart(8, "0")
const leHex = (v) => [0, 8, 16, 24].map((s) => ((v >>> s) & 255).toString(16).padStart(2, "0")).join("")

/** 字节串补位成 32 位字（MD5 小端、SHA 大端），末尾写比特长度。 */
function padWords(bytes, littleEndian) {
  const n = bytes.length
  const total = (((n + 8) >> 6) + 1) * 16
  const w = new Array(total).fill(0)
  const shift = (i) => (littleEndian ? (i % 4) * 8 : 24 - (i % 4) * 8)
  for (let i = 0; i < n; i++) w[i >> 2] |= bytes.charCodeAt(i) << shift(i)
  w[n >> 2] |= 0x80 << shift(n)
  const low = (n * 8) >>> 0, high = Math.floor((n * 8) / 0x100000000)
  if (littleEndian) { w[total - 2] = low; w[total - 1] = high }
  else { w[total - 2] = high; w[total - 1] = low }
  return w
}

function md5(text) {
  const w = padWords(utf8Bytes(text), true)
  let a = 0x67452301, b = 0xefcdab89, c = 0x98badcfe, d = 0x10325476
  for (let i = 0; i < w.length; i += 16) {
    let A = a, B = b, C = c, D = d
    for (let j = 0; j < 64; j++) {
      let f, g
      if (j < 16) { f = (B & C) | (~B & D); g = j }
      else if (j < 32) { f = (D & B) | (~D & C); g = (5 * j + 1) % 16 }
      else if (j < 48) { f = B ^ C ^ D; g = (3 * j + 5) % 16 }
      else { f = C ^ (B | ~D); g = (7 * j) % 16 }
      const next = D
      D = C
      C = B
      B = (B + rotl((A + f + MD5_K[j] + w[i + g]) | 0, MD5_S[(j >> 4) * 4 + (j % 4)])) | 0
      A = next
    }
    a = (a + A) | 0; b = (b + B) | 0; c = (c + C) | 0; d = (d + D) | 0
  }
  return [a, b, c, d].map(leHex).join("")
}

function sha1(text) {
  const w = padWords(utf8Bytes(text), false)
  const h = [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0]
  const W = new Array(80)
  for (let i = 0; i < w.length; i += 16) {
    for (let j = 0; j < 80; j++) W[j] = j < 16 ? w[i + j] : rotl(W[j - 3] ^ W[j - 8] ^ W[j - 14] ^ W[j - 16], 1)
    let [a, b, c, d, e] = h
    for (let j = 0; j < 80; j++) {
      let f, k
      if (j < 20) { f = (b & c) | (~b & d); k = 0x5a827999 }
      else if (j < 40) { f = b ^ c ^ d; k = 0x6ed9eba1 }
      else if (j < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8f1bbcdc }
      else { f = b ^ c ^ d; k = 0xca62c1d6 }
      const next = (rotl(a, 5) + f + e + k + W[j]) | 0
      e = d; d = c; c = rotl(b, 30); b = a; a = next
    }
    h[0] = (h[0] + a) | 0; h[1] = (h[1] + b) | 0; h[2] = (h[2] + c) | 0; h[3] = (h[3] + d) | 0; h[4] = (h[4] + e) | 0
  }
  return h.map(beHex).join("")
}

function sha256(text) {
  const w = padWords(utf8Bytes(text), false)
  const h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
  const W = new Array(64)
  for (let i = 0; i < w.length; i += 16) {
    for (let j = 0; j < 64; j++) {
      if (j < 16) { W[j] = w[i + j]; continue }
      const s0 = rotr(W[j - 15], 7) ^ rotr(W[j - 15], 18) ^ (W[j - 15] >>> 3)
      const s1 = rotr(W[j - 2], 17) ^ rotr(W[j - 2], 19) ^ (W[j - 2] >>> 10)
      W[j] = (W[j - 16] + s0 + W[j - 7] + s1) | 0
    }
    let [a, b, c, d, e, f, g, hh] = h
    for (let j = 0; j < 64; j++) {
      const t1 = (hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + SHA256_K[j] + W[j]) | 0
      const t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) | 0
      hh = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0
    }
    const next = [a, b, c, d, e, f, g, hh]
    for (let k = 0; k < 8; k++) h[k] = (h[k] + next[k]) | 0
  }
  return h.map(beHex).join("")
}

// MARK: - 识别出来的格式

/** JWT：header.payload.signature，header 是带 alg 的 JSON。解不开返回 null（不验签名，只看内容）。 */
function decodeJWT(text) {
  const m = /^([A-Za-z0-9_-]{4,})\.([A-Za-z0-9_-]{4,})\.([A-Za-z0-9_-]*)$/.exec(text)
  if (!m) return null
  try {
    const header = JSON.parse(base64Decode(m[1]))
    const payload = JSON.parse(base64Decode(m[2]))
    if (!header || typeof header !== "object" || !header.alg || !payload || typeof payload !== "object") return null
    return { header, payload }
  } catch (e) {
    return null
  }
}

/** 离现在多久：「还有 3 天」「已过期 2 小时」。 */
function relative(ms, nowMs) {
  const diff = ms - nowMs
  const abs = Math.abs(diff) / 1000
  const [n, zh, hant, en] = abs < 3600 ? [Math.max(1, Math.round(abs / 60)), "分钟", "分鐘", "min"]
    : abs < 86400 ? [Math.round(abs / 3600), "小时", "小時", "h"]
    : [Math.round(abs / 86400), "天", "天", "d"]
  return diff >= 0 ? t(`还有 ${n} ${zh}`, `還有 ${n} ${hant}`, `in ${n}${en}`)
                   : t(`已过期 ${n} ${zh}`, `已過期 ${n} ${hant}`, `expired ${n}${en} ago`)
}

/** 整数换进制：十进制、0x、0b、0o 都认（BigInt，多长都行）。不是整数返回 null。 */
function parseInteger(text) {
  const s = text.replace(/_/g, "")
  // BigInt 换进制是平方级的，粘贴一串几万位的数字会撞上 2 秒的执行时限；64 位以内够用了
  if (s.length > 66) return null
  if (/^-?(0|[1-9]\d*)$/.test(s)) return { value: BigInt(s), base: 10 }
  const m = /^(-?)0([xbo])([0-9a-f]+)$/i.exec(s)
  if (!m) return null
  const base = { x: 16, b: 2, o: 8 }[m[2].toLowerCase()]
  const digits = m[3].toLowerCase()
  if (!digits.split("").every((ch) => parseInt(ch, 16) < base)) return null
  const v = BigInt("0" + m[2].toLowerCase() + digits)
  return { value: m[1] ? -v : v, base }
}

function radix(v, base, prefix) {
  return (v < 0n ? "-" : "") + prefix + (v < 0n ? -v : v).toString(base)
}

/** 颜色：#RGB / #RRGGBB / #RRGGBBAA、rgb()/rgba()、hsl()/hsla() → { r, g, b, a }。 */
function parseColor(text) {
  const s = text.trim().toLowerCase()
  let m = /^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/.exec(s)
  if (m) {
    const h = m[1].length === 3 ? m[1].split("").map((c) => c + c).join("") : m[1]
    const n = (i) => parseInt(h.slice(i, i + 2), 16)
    return { r: n(0), g: n(2), b: n(4), a: h.length === 8 ? Math.round((n(6) / 255) * 100) / 100 : 1 }
  }
  const num = "(\\d+(?:\\.\\d+)?)"
  m = new RegExp(`^rgba?\\(\\s*${num}[,\\s]+${num}[,\\s]+${num}(?:\\s*[,/]\\s*${num}(%?))?\\s*\\)$`).exec(s)
  if (m) {
    const [r, g, b] = [m[1], m[2], m[3]].map(Number)
    if ([r, g, b].some((x) => x > 255)) return null
    const a = m[4] == null ? 1 : Number(m[4]) / (m[5] ? 100 : 1)
    return a > 1 ? null : { r: Math.round(r), g: Math.round(g), b: Math.round(b), a }
  }
  m = new RegExp(`^hsla?\\(\\s*${num}(?:deg)?[,\\s]+${num}%[,\\s]+${num}%(?:\\s*[,/]\\s*${num}(%?))?\\s*\\)$`).exec(s)
  if (m) {
    const [h, sat, l] = [Number(m[1]) % 360, Number(m[2]) / 100, Number(m[3]) / 100]
    if (sat > 1 || l > 1) return null
    const a = m[4] == null ? 1 : Number(m[4]) / (m[5] ? 100 : 1)
    const k = (n) => (n + h / 30) % 12
    const q = sat * Math.min(l, 1 - l)
    const f = (n) => Math.round((l - q * Math.max(-1, Math.min(k(n) - 3, 9 - k(n), 1))) * 255)
    return a > 1 ? null : { r: f(0), g: f(8), b: f(4), a }
  }
  return null
}

function colorHex(c) {
  const h = (n) => n.toString(16).padStart(2, "0")
  return "#" + h(c.r) + h(c.g) + h(c.b) + (c.a < 1 ? h(Math.round(c.a * 255)) : "")
}

function colorHSL(c) {
  const r = c.r / 255, g = c.g / 255, b = c.b / 255
  const max = Math.max(r, g, b), min = Math.min(r, g, b), l = (max + min) / 2
  let h = 0, s = 0
  if (max !== min) {
    const d = max - min
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min)
    h = max === r ? (g - b) / d + (g < b ? 6 : 0) : max === g ? (b - r) / d + 2 : (r - g) / d + 4
    h *= 60
  }
  const body = `${Math.round(h)}, ${Math.round(s * 100)}%, ${Math.round(l * 100)}%`
  return c.a < 1 ? `hsla(${body}, ${c.a})` : `hsl(${body})`
}

function colorRGB(c) {
  return c.a < 1 ? `rgba(${c.r}, ${c.g}, ${c.b}, ${c.a})` : `rgb(${c.r}, ${c.g}, ${c.b})`
}

/** 网址里的查询参数：[[名字, 值]]（值解码，+ 当空格）。不是 http(s) 网址或没有参数返回空。 */
function queryParams(text) {
  if (!/^https?:\/\/\S+\?\S/i.test(text)) return []
  const query = text.split("#")[0].split("?").slice(1).join("?")
  const decode = (s) => { try { return decodeURIComponent(s.replace(/\+/g, " ")) } catch (e) { return s } }
  return query.split("&").filter(Boolean).slice(0, 30).map((pair) => {
    const i = pair.indexOf("=")
    return i < 0 ? [decode(pair), ""] : [decode(pair.slice(0, i)), decode(pair.slice(i + 1))]
  })
}

/** 非 ASCII 字符写成 \uXXXX（UTF-16，表情是两个）。 */
function unicodeEscape(text) {
  let out = ""
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i)
    out += code > 0x7e ? "\\u" + code.toString(16).padStart(4, "0") : text[i]
  }
  return out
}

function unicodeUnescape(text) {
  return text
    .replace(/\\u\{([0-9a-fA-F]{1,6})\}/g, (m, hex) => (parseInt(hex, 16) <= 0x10ffff ? String.fromCodePoint(parseInt(hex, 16)) : m))
    .replace(/\\u([0-9a-fA-F]{4})/g, (m, hex) => String.fromCharCode(parseInt(hex, 16)))
    .replace(/\\x([0-9a-fA-F]{2})/g, (m, hex) => String.fromCharCode(parseInt(hex, 16)))
}

const HTML_NAMED = {
  amp: "&", lt: "<", gt: ">", quot: "\"", apos: "'", nbsp: " ", copy: "©", reg: "®", trade: "™",
  hellip: "…", mdash: "—", ndash: "–", laquo: "«", raquo: "»", middot: "·", times: "×", divide: "÷",
  yen: "¥", euro: "€", pound: "£", cent: "¢", sect: "§", deg: "°", plusmn: "±", para: "¶",
  ldquo: "“", rdquo: "”", lsquo: "‘", rsquo: "’", bull: "•",
}

function htmlDecode(text) {
  return text.replace(/&(#\d{1,7}|#x[0-9a-fA-F]{1,6}|[a-zA-Z]+);/g, (m, body) => {
    if (body[0] === "#") {
      const code = body[1] === "x" || body[1] === "X" ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10)
      return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : m
    }
    return HTML_NAMED[body] != null ? HTML_NAMED[body] : m
  })
}

function htmlEncode(text) {
  return text.replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;" })[ch])
}

/** JSON 字符串转义（不带外面的引号）。 */
function jsonEscape(text) {
  return JSON.stringify(text).slice(1, -1)
}

/** JSON 字符串反转义：日志里的 {\"a\":1}、带不带外面的引号都行。不是合法的转义返回 null。 */
function jsonUnescape(text) {
  if (!/\\["\\\/bfnrtu]/.test(text)) return null
  const quoted = /^".*"$/s.test(text) ? text : "\"" + text + "\""
  try {
    const value = JSON.parse(quoted)
    return typeof value === "string" ? value : null
  } catch (e) {
    return null
  }
}

/** 金额 → 中文大写（壹仟零伍元整）。整数部分最多 12 位（9999 亿）。不是金额返回 null。 */
function chineseAmount(text, hant) {
  const s = text.replace(/^[¥￥]\s*/, "").replace(/^(\d{1,3}(,\d{3})+)(\.\d+)?$/, (m) => m.replace(/,/g, ""))
  const m = /^(0|[1-9]\d{0,11})(?:\.(\d{1,2}))?$/.exec(s)
  if (!m) return null
  const D = hant ? "零壹貳參肆伍陸柒捌玖" : "零壹贰叁肆伍陆柒捌玖"
  const SMALL = ["", "拾", "佰", "仟"]
  const BIG = hant ? ["", "萬", "億"] : ["", "万", "亿"]
  const int = m[1]
  let out = ""
  let zero = false
  for (let i = 0; i < int.length; i++) {
    const d = +int[i], p = int.length - 1 - i
    if (d === 0) zero = true
    else {
      if (zero && out) out += "零"
      zero = false
      out += D[d] + SMALL[p % 4]
    }
    // 万、亿：这一段（四位）里有不是 0 的才写
    if (p % 4 === 0 && p > 0 && /[1-9]/.test(int.slice(Math.max(0, i - 3), i + 1))) out += BIG[p / 4]
  }
  const dec = (m[2] || "").padEnd(2, "0")
  const jiao = +dec[0], fen = +dec[1]
  if (!jiao && !fen) return (out || D[0]) + "元整"
  let tail = ""
  if (jiao) tail += D[jiao] + "角"
  if (fen) tail += (!jiao && out ? D[0] : "") + D[fen] + "分"
  return (out ? out + "元" : "") + tail
}

function pad(n) {
  return String(n).padStart(2, "0")
}

/** 本地时间 2026-11-06 18:30:05 */
function localDate(ms) {
  const d = new Date(ms)
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`
}

/** 随机 UUID v4（JSC 里没有 crypto，用 Math.random；当标识用够了，别拿来当密钥）。 */
function uuid() {
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (ch) => {
    const r = Math.floor(Math.random() * 16)
    return (ch === "x" ? r : (r & 3) | 8).toString(16)
  })
}

function words(text) {
  return String(text).trim().replace(/([a-z0-9])([A-Z])/g, "$1 $2").split(/[\s_\-]+/).filter(Boolean)
}

/** 输入能做的转换：[{ name, value }]，只列有意义的（解不开的不列）。 */
function conversions(input, nowMs = Date.now()) {
  const text = String(input)
  const trimmed = text.trim()
  const out = []
  if (!trimmed) {
    out.push({ name: t("随机 UUID", "隨機 UUID", "Random UUID"), value: uuid() })
    out.push({ name: t("当前时间戳（秒）", "目前時間戳（秒）", "Current timestamp (s)"), value: String(Math.floor(nowMs / 1000)) })
    out.push({ name: t("当前时间戳（毫秒）", "目前時間戳（毫秒）", "Current timestamp (ms)"), value: String(nowMs) })
    out.push({ name: t("当前时间（ISO）", "目前時間（ISO）", "Current time (ISO)"), value: new Date(nowMs).toISOString() })
    return out
  }
  out.push(...jwtItems(trimmed, nowMs), ...timeItems(trimmed))
  // 进制：十进制给十六 / 二 / 八进制，带前缀的给十进制和十六（或二）进制
  const integer = parseInteger(trimmed)
  if (integer) {
    const v = integer.value
    const targets = {
      10: [[t("十六进制", "十六進位", "Hex"), 16, "0x"], [t("二进制", "二進位", "Binary"), 2, "0b"], [t("八进制", "八進位", "Octal"), 8, "0o"]],
      16: [[t("十进制", "十進位", "Decimal"), 10, ""], [t("二进制", "二進位", "Binary"), 2, "0b"]],
      2: [[t("十进制", "十進位", "Decimal"), 10, ""], [t("十六进制", "十六進位", "Hex"), 16, "0x"]],
      8: [[t("十进制", "十進位", "Decimal"), 10, ""], [t("十六进制", "十六進位", "Hex"), 16, "0x"]],
    }[integer.base]
    for (const [name, base, prefix] of targets) out.push({ name, value: radix(v, base, prefix) })
  }
  // 金额大写：只给中文界面（壹仟零伍元整）
  if (LANG === "zh" || LANG === "zh-Hant") {
    const amount = chineseAmount(trimmed, LANG === "zh-Hant")
    if (amount) out.push({ name: t("人民币大写", "中文大寫金額", "Chinese amount"), value: amount })
  }
  // 颜色：互转，行首画成那个颜色
  const color = parseColor(trimmed)
  if (color) {
    const swatch = colorHex({ r: color.r, g: color.g, b: color.b, a: 1 })
    const lower = trimmed.toLowerCase()
    const forms = [["HEX", colorHex(color)], ["RGB", colorRGB(color)], ["HSL", colorHSL(color)]]
    for (const [name, value] of forms) {
      if (value.toLowerCase() !== lower) out.push({ name: t("颜色 ", "顏色 ", "Color ") + name, value, swatch })
    }
  }
  // JSON：格式化、压缩
  if (/^[\[{]/.test(trimmed)) {
    try {
      const value = JSON.parse(trimmed)
      out.push({ name: t("JSON 格式化", "JSON 格式化", "Format JSON"), value: JSON.stringify(value, null, 2) })
      out.push({ name: t("JSON 压缩", "JSON 壓縮", "Minify JSON"), value: JSON.stringify(value) })
    } catch (e) {
      out.push({ name: t("JSON 解析不了", "JSON 解析不了", "Not valid JSON"), value: String(e.message || e), invalid: true })
    }
  }
  for (const [key, value] of queryParams(trimmed)) {
    out.push({ name: t("网址参数 · ", "網址參數 · ", "Query · ") + key, value })
  }
  const decoded = base64Decode(trimmed)
  if (decoded != null) out.push({ name: t("Base64 解码", "Base64 解碼", "Base64 decode"), value: decoded })
  if (/%[0-9A-Fa-f]{2}/.test(text)) {
    try {
      const d = decodeURIComponent(text)
      if (d !== text) out.push({ name: t("URL 解码", "URL 解碼", "URL decode"), value: d })
    } catch (e) { /* 不是合法的编码 */ }
  }
  const unescaped = unicodeUnescape(text)
  if (unescaped !== text) out.push({ name: t("Unicode 反转义", "Unicode 反跳脫", "Unicode unescape"), value: unescaped })
  const entities = htmlDecode(text)
  if (entities !== text) out.push({ name: t("HTML 实体解码", "HTML 實體解碼", "HTML entity decode"), value: entities })
  const jsonText = jsonUnescape(trimmed)
  if (jsonText != null && jsonText !== trimmed) out.push({ name: t("JSON 字符串反转义", "JSON 字串反跳脫", "JSON string unescape"), value: jsonText })
  out.push({ name: t("Base64 编码", "Base64 編碼", "Base64 encode"), value: base64Encode(text) })
  const encoded = encodeURIComponent(text)
  if (encoded !== text) out.push({ name: t("URL 编码", "URL 編碼", "URL encode"), value: encoded })
  if (/[^\x00-\x7e]/.test(text)) out.push({ name: t("Unicode 转义", "Unicode 跳脫", "Unicode escape"), value: unicodeEscape(text) })
  const html = htmlEncode(text)
  if (html !== text) out.push({ name: t("HTML 转义", "HTML 跳脫", "HTML escape"), value: html })
  const escaped = jsonEscape(text)
  if (escaped !== text) out.push({ name: t("JSON 字符串转义", "JSON 字串跳脫", "JSON string escape"), value: escaped })
  // 大小写、命名风格：只给像标识符的（字母数字加空格、下划线、连字符）
  if (/^[A-Za-z][A-Za-z0-9 _\-]*$/.test(trimmed) && trimmed.length <= 200) {
    const w = words(trimmed).map((x) => x.toLowerCase())
    const camel = w.map((x, i) => (i ? x[0].toUpperCase() + x.slice(1) : x)).join("")
    const variants = [
      [t("驼峰", "駝峰", "camelCase"), camel],
      [t("帕斯卡", "帕斯卡", "PascalCase"), camel[0].toUpperCase() + camel.slice(1)],
      [t("下划线", "底線", "snake_case"), w.join("_")],
      [t("短横线", "連字號", "kebab-case"), w.join("-")],
      [t("全大写", "全大寫", "UPPER CASE"), trimmed.toUpperCase()],
      [t("全小写", "全小寫", "lower case"), trimmed.toLowerCase()],
    ]
    for (const [name, value] of variants) if (value !== trimmed) out.push({ name, value })
  }
  const bytes = utf8Bytes(text).length
  // 哈希按字节算，JSC 里 1 MB 三种要将近 1 秒（2026-11-06 量的），粘贴大段文字时只给 128 KB 以内的
  if (bytes <= 1 << 17) {
    out.push({ name: "MD5", value: md5(text) })
    out.push({ name: "SHA-1", value: sha1(text) })
    out.push({ name: "SHA-256", value: sha256(text) })
  }
  out.push(countItem(text))
  return out
}

/** JWT：载荷、头、过期时间（不验签名）。不是 JWT 回空。 */
function jwtItems(trimmed, nowMs) {
  const jwt = decodeJWT(trimmed)
  if (!jwt) return []
  const out = [
    { name: t("JWT 载荷", "JWT 載荷", "JWT payload"), value: JSON.stringify(jwt.payload, null, 2) },
    { name: t("JWT 头", "JWT 標頭", "JWT header"), value: JSON.stringify(jwt.header, null, 2) },
  ]
  if (typeof jwt.payload.exp === "number") {
    out.push({ name: t("JWT 过期时间", "JWT 過期時間", "JWT expires") + " · " + relative(jwt.payload.exp * 1000, nowMs),
               value: localDate(jwt.payload.exp * 1000) })
  }
  if (typeof jwt.payload.iat === "number") {
    out.push({ name: t("JWT 签发时间", "JWT 簽發時間", "JWT issued"), value: localDate(jwt.payload.iat * 1000) })
  }
  return out
}

/** 时间戳（10 位秒、13 位毫秒）→ 日期；认得出的日期写法（2026-11-06、2026/11/06 18:30、ISO）→ 时间戳。 */
function timeItems(trimmed) {
  const out = []
  if (/^\d{10}$|^\d{13}$/.test(trimmed)) {
    const ms = trimmed.length === 10 ? parseInt(trimmed, 10) * 1000 : parseInt(trimmed, 10)
    out.push({ name: t("时间戳 → 本地时间", "時間戳 → 本地時間", "Timestamp → local time"), value: localDate(ms) })
    out.push({ name: t("时间戳 → ISO（UTC）", "時間戳 → ISO（UTC）", "Timestamp → ISO (UTC)"), value: new Date(ms).toISOString() })
  }
  if (/\d{4}[-/]\d{1,2}[-/]\d{1,2}/.test(trimmed)) {
    const ms = Date.parse(trimmed.replace(/\//g, "-").replace(" ", "T"))
    if (isFinite(ms)) {
      out.push({ name: t("日期 → 时间戳（秒）", "日期 → 時間戳（秒）", "Date → timestamp (s)"), value: String(Math.floor(ms / 1000)) })
      out.push({ name: t("日期 → 时间戳（毫秒）", "日期 → 時間戳（毫秒）", "Date → timestamp (ms)"), value: String(ms) })
    }
  }
  return out
}

/** 字数 · 字节 · 行数 */
function countItem(text) {
  const lines = text.split("\n").length
  const bytes = utf8Bytes(text).length
  return {
    name: t("字数", "字數", "Length"),
    value: t(`${[...text].length} 个字 · ${bytes} 字节 · ${lines} 行`, `${[...text].length} 個字 · ${bytes} 位元組 · ${lines} 行`,
             `${[...text].length} chars · ${bytes} bytes · ${lines} lines`),
    stat: true,
  }
}

// MARK: - 工具目录（用户 2026-11-07：「不知道有啥命令」）
//
// 进开发工具箱没输入时列出全部工具；有输入时照旧自动识别（`conversions`），名字对得上的工具排最前；
// 在工具上回车进它自己那一层（TabFlick 的 enter 动作），只列这个工具的结果。
// 老版本 TabFlick 不认 enter（`tabflick.features` 里没有）：目录照样列，只是进不去，粘贴照旧能用。

const LEVELS = typeof tabflick !== "undefined" && Array.isArray(tabflick.features) && tabflick.features.indexOf("enter") >= 0

const CAT = {
  gen: () => t("生成", "產生", "Generate"),
  time: () => t("时间", "時間", "Time"),
  data: () => t("数据", "資料", "Data"),
  code: () => t("编码", "編碼", "Encoding"),
  num: () => t("数字", "數字", "Numbers"),
  text: () => t("文本", "文字", "Text"),
}

/** 不知道在等什么时那句话。 */
const notRecognized = (what) => ({ value: what, invalid: true })

/** 当前这个 UUID：拷走之后才换新的（面板开着每 5 秒刷新一次，每次都换的话正看着就变了）。 */
let currentUUID = null
function stableUUID() {
  if (!currentUUID) currentUUID = uuid()
  return currentUUID
}

/**
 * 全部工具，按类别排。
 *   glyph / tint：行首方块；keys：除了名字之外打什么能找到它（英文、拼音首字母）；
 *   generator：不用输入，目录里直接给值、回车拷贝；run(text, nowMs)：这个工具对输入的结果 [{name, value}]。
 */
const TOOLS = [
  {
    id: "uuid", glyph: "ID", tint: "indigo", cat: CAT.gen, generator: true,
    name: () => t("随机 UUID", "隨機 UUID", "Random UUID"),
    hint: () => t("回车拷贝，拷完换一个新的", "按 ↩ 拷貝，拷完換一個新的", "↩ copies, then a new one is made"),
    keys: ["uuid", "guid", "sjuuid"],
    run() {
      const id = stableUUID()
      return [
        { name: t("小写", "小寫", "Lowercase"), value: id },
        { name: t("大写", "大寫", "Uppercase"), value: id.toUpperCase() },
        { name: t("不带连字符", "不帶連字號", "No hyphens"), value: id.replace(/-/g, "") },
      ]
    },
  },
  {
    id: "now", glyph: "TS", tint: "orange", cat: CAT.gen, generator: true,
    name: () => t("当前时间戳", "目前時間戳", "Current timestamp"),
    hint: () => t("秒、毫秒、ISO、本地时间", "秒、毫秒、ISO、本地時間", "Seconds, milliseconds, ISO, local time"),
    keys: ["now", "timestamp", "unix", "dqsjc", "sjc"],
    run(text, nowMs) {
      return [
        { name: t("秒", "秒", "Seconds"), value: String(Math.floor(nowMs / 1000)) },
        { name: t("毫秒", "毫秒", "Milliseconds"), value: String(nowMs) },
        { name: "ISO（UTC）", value: new Date(nowMs).toISOString() },
        { name: t("本地时间", "本地時間", "Local time"), value: localDate(nowMs) },
      ]
    },
  },
  {
    id: "time", glyph: "⇄", tint: "orange", cat: CAT.time,
    name: () => t("时间戳 ↔ 日期", "時間戳 ↔ 日期", "Timestamp ↔ date"),
    hint: () => t("10 位秒、13 位毫秒，或 2025-11-06 这样的日期", "10 位秒、13 位毫秒，或 2025-11-06 這樣的日期",
                  "10-digit seconds, 13-digit milliseconds, or a date like 2025-11-06"),
    placeholder: () => t("1762425000、2025-11-06 18:30", "1762425000、2025-11-06 18:30", "1762425000 or 2025-11-06 18:30"),
    keys: ["timestamp", "date", "time", "sjc", "rq", "日期", "时间戳"],
    run(text) {
      const out = timeItems(text.trim())
      return out.length ? out : [notRecognized(t("认不出时间戳或日期", "認不出時間戳或日期", "Not a timestamp or date"))]
    },
  },
  {
    id: "jwt", glyph: "JW", tint: "purple", cat: CAT.data,
    name: () => t("JWT 解码", "JWT 解碼", "Decode JWT"),
    hint: () => t("看载荷、头和过期时间，不验签名", "看載荷、標頭和過期時間，不驗簽章", "Payload, header and expiry. Signature isn't checked"),
    placeholder: () => t("粘贴 JWT", "貼上 JWT", "Paste a JWT"),
    keys: ["jwt", "token"],
    run(text, nowMs) {
      const out = jwtItems(text.trim(), nowMs)
      return out.length ? out : [notRecognized(t("不是 JWT", "不是 JWT", "Not a JWT"))]
    },
  },
  {
    id: "json", glyph: "{}", tint: "green", cat: CAT.data,
    name: () => t("JSON 格式化 / 压缩", "JSON 格式化 / 壓縮", "Format / minify JSON"),
    hint: () => t("缩进排好，或者压成一行", "縮排排好，或者壓成一行", "Pretty-print or squeeze onto one line"),
    placeholder: () => t("粘贴 JSON", "貼上 JSON", "Paste JSON"),
    keys: ["json", "format", "minify", "gsh", "格式化"],
    run(text) {
      try {
        const value = JSON.parse(text.trim())
        return [
          { name: t("JSON 格式化", "JSON 格式化", "Format JSON"), value: JSON.stringify(value, null, 2) },
          { name: t("JSON 压缩", "JSON 壓縮", "Minify JSON"), value: JSON.stringify(value) },
        ]
      } catch (e) {
        return [{ name: t("JSON 解析不了", "JSON 解析不了", "Not valid JSON"), value: String(e.message || e), invalid: true }]
      }
    },
  },
  {
    id: "query", glyph: "?=", tint: "green", cat: CAT.data,
    name: () => t("网址参数", "網址參數", "URL query parameters"),
    hint: () => t("把网址里的参数逐个列出来、解码", "把網址裡的參數逐個列出來、解碼", "List and decode each parameter of a URL"),
    placeholder: () => t("粘贴带参数的网址", "貼上帶參數的網址", "Paste a URL with parameters"),
    keys: ["query", "params", "url", "wzcs", "参数"],
    run(text) {
      const out = queryParams(text.trim()).map(([key, value]) => ({ name: key, value }))
      return out.length ? out : [notRecognized(t("网址里没有参数", "網址裡沒有參數", "No query parameters"))]
    },
  },
  {
    id: "base64", glyph: "64", tint: "blue", cat: CAT.code,
    name: () => t("Base64 编码 / 解码", "Base64 編碼 / 解碼", "Base64 encode / decode"),
    hint: () => t("中文按 UTF-8，认 URL 安全的写法", "中文按 UTF-8，認 URL 安全的寫法", "UTF-8, URL-safe input accepted"),
    placeholder: () => t("输入要编码或解码的文字", "輸入要編碼或解碼的文字", "Text to encode or decode"),
    keys: ["base64", "b64"],
    run(text) {
      const decoded = base64Decode(text.trim())
      return [{ name: t("Base64 编码", "Base64 編碼", "Base64 encode"), value: base64Encode(text) }]
        .concat(decoded != null ? [{ name: t("Base64 解码", "Base64 解碼", "Base64 decode"), value: decoded }] : [])
    },
  },
  {
    id: "url", glyph: "%", tint: "blue", cat: CAT.code,
    name: () => t("URL 编码 / 解码", "URL 編碼 / 解碼", "URL encode / decode"),
    hint: () => t("百分号编码", "百分號編碼", "Percent-encoding"),
    placeholder: () => t("输入要编码或解码的文字", "輸入要編碼或解碼的文字", "Text to encode or decode"),
    keys: ["url", "urlencode", "encode", "decode", "percent", "bm", "jm", "编码", "解码"],
    run(text) {
      const out = [{ name: t("URL 编码", "URL 編碼", "URL encode"), value: encodeURIComponent(text) }]
      try {
        const d = decodeURIComponent(text)
        if (d !== text) out.push({ name: t("URL 解码", "URL 解碼", "URL decode"), value: d })
      } catch (e) { /* 不是合法的编码 */ }
      return out
    },
  },
  {
    id: "unicode", glyph: "\\u", tint: "blue", cat: CAT.code,
    name: () => t("Unicode 转义 / 反转义", "Unicode 跳脫 / 反跳脫", "Unicode escape / unescape"),
    hint: () => t("\\u4f60 这种写法和文字互转", "\\u4f60 這種寫法和文字互轉", "Convert between text and \\u4f60 escapes"),
    placeholder: () => t("输入文字，或 \\u 开头的转义", "輸入文字，或 \\u 開頭的跳脫", "Text, or \\u escapes"),
    keys: ["unicode", "escape", "unescape", "zy", "转义"],
    run(text) {
      const out = [{ name: t("Unicode 转义", "Unicode 跳脫", "Unicode escape"), value: unicodeEscape(text) }]
      const unescaped = unicodeUnescape(text)
      if (unescaped !== text) out.push({ name: t("Unicode 反转义", "Unicode 反跳脫", "Unicode unescape"), value: unescaped })
      return out
    },
  },
  {
    id: "html", glyph: "&;", tint: "blue", cat: CAT.code,
    name: () => t("HTML 转义 / 实体解码", "HTML 跳脫 / 實體解碼", "HTML escape / decode entities"),
    hint: () => t("< > & 和 &amp; 这类实体互转", "< > & 和 &amp; 這類實體互轉", "Convert between < > & and entities like &amp;"),
    placeholder: () => t("输入 HTML 或带实体的文字", "輸入 HTML 或帶實體的文字", "HTML, or text with entities"),
    keys: ["html", "entity", "escape", "st", "实体"],
    run(text) {
      const out = [{ name: t("HTML 转义", "HTML 跳脫", "HTML escape"), value: htmlEncode(text) }]
      const decoded = htmlDecode(text)
      if (decoded !== text) out.push({ name: t("HTML 实体解码", "HTML 實體解碼", "HTML entity decode"), value: decoded })
      return out
    },
  },
  {
    id: "jsonstr", glyph: "\"\"", tint: "blue", cat: CAT.code,
    name: () => t("JSON 字符串转义 / 反转义", "JSON 字串跳脫 / 反跳脫", "JSON string escape / unescape"),
    hint: () => t("引号、换行这些写成 \\\" \\n，或者反过来", "引號、換行這些寫成 \\\" \\n，或者反過來", "Quotes and newlines to \\\" \\n, and back"),
    placeholder: () => t("输入文字，或带 \\n 的字符串", "輸入文字，或帶 \\n 的字串", "Text, or a string with \\n"),
    keys: ["json", "string", "escape", "zfc", "转义"],
    run(text) {
      const out = [{ name: t("JSON 字符串转义", "JSON 字串跳脫", "JSON string escape"), value: jsonEscape(text) }]
      const unescaped = jsonUnescape(text.trim())
      if (unescaped != null && unescaped !== text.trim()) {
        out.push({ name: t("JSON 字符串反转义", "JSON 字串反跳脫", "JSON string unescape"), value: unescaped })
      }
      return out
    },
  },
  {
    id: "radix", glyph: "0x", tint: "pink", cat: CAT.num,
    name: () => t("进制转换", "進位轉換", "Number bases"),
    hint: () => t("十进制、十六进制、二进制、八进制互转", "十進位、十六進位、二進位、八進位互轉", "Decimal, hex, binary and octal"),
    placeholder: () => t("255、0xff、0b1010、0o17", "255、0xff、0b1010、0o17", "255, 0xff, 0b1010, 0o17"),
    keys: ["radix", "hex", "binary", "bin", "oct", "decimal", "jz", "进制"],
    run(text) {
      const integer = parseInteger(text.trim())
      if (!integer) return [notRecognized(t("不是整数", "不是整數", "Not an integer"))]
      const v = integer.value
      return [
        [t("十进制", "十進位", "Decimal"), 10, ""], [t("十六进制", "十六進位", "Hex"), 16, "0x"],
        [t("二进制", "二進位", "Binary"), 2, "0b"], [t("八进制", "八進位", "Octal"), 8, "0o"],
      ].map(([name, base, prefix]) => ({ name, value: radix(v, base, prefix) }))
    },
  },
  {
    id: "color", glyph: "#", tint: "pink", cat: CAT.num,
    name: () => t("颜色转换", "顏色轉換", "Color formats"),
    hint: () => t("HEX、RGB、HSL 互转", "HEX、RGB、HSL 互轉", "HEX, RGB and HSL"),
    placeholder: () => t("#ff9500、rgb(255, 149, 0)", "#ff9500、rgb(255, 149, 0)", "#ff9500 or rgb(255, 149, 0)"),
    keys: ["color", "colour", "hex", "rgb", "hsl", "ys", "颜色"],
    run(text) {
      const color = parseColor(text.trim())
      if (!color) return [notRecognized(t("认不出颜色", "認不出顏色", "Not a color"))]
      const swatch = colorHex({ r: color.r, g: color.g, b: color.b, a: 1 })
      return [["HEX", colorHex(color)], ["RGB", colorRGB(color)], ["HSL", colorHSL(color)]]
        .map(([name, value]) => ({ name: t("颜色 ", "顏色 ", "Color ") + name, value, swatch }))
    },
  },
  {
    id: "amount", glyph: "¥", tint: "red", cat: CAT.num, chineseOnly: true,
    name: () => t("人民币大写", "中文大寫金額", "Chinese amount"),
    hint: () => t("金额写成壹仟零伍元整，最多 12 位整数", "金額寫成壹仟零伍元整，最多 12 位整數", "Up to 12 integer digits"),
    placeholder: () => t("1234.56", "1234.56", "1234.56"),
    keys: ["rmb", "amount", "dx", "je", "大写", "金额"],
    run(text) {
      const amount = chineseAmount(text.trim(), LANG === "zh-Hant")
      return amount ? [{ name: t("人民币大写", "中文大寫金額", "Chinese amount"), value: amount }]
        : [notRecognized(t("不是金额（最多 12 位整数、2 位小数）", "不是金額（最多 12 位整數、2 位小數）", "Not an amount"))]
    },
  },
  {
    id: "case", glyph: "Aa", tint: "teal", cat: CAT.text,
    name: () => t("命名风格", "命名風格", "Naming styles"),
    hint: () => t("驼峰、帕斯卡、下划线、短横线、大小写", "駝峰、帕斯卡、底線、連字號、大小寫", "camelCase, PascalCase, snake_case, kebab-case, upper and lower"),
    placeholder: () => t("user name、userName、user_name", "user name、userName、user_name", "user name, userName, user_name"),
    keys: ["case", "camel", "snake", "kebab", "pascal", "upper", "lower", "mmfg", "tf", "驼峰", "命名"],
    run(text) {
      const trimmed = text.trim()
      if (!/^[A-Za-z][A-Za-z0-9 _\-]*$/.test(trimmed) || trimmed.length > 200) {
        return [notRecognized(t("只认字母、数字、空格、_ 和 -，以字母开头", "只認字母、數字、空格、_ 和 -，以字母開頭",
                                "Letters, digits, spaces, _ and - only, starting with a letter"))]
      }
      const w = words(trimmed).map((x) => x.toLowerCase())
      const camel = w.map((x, i) => (i ? x[0].toUpperCase() + x.slice(1) : x)).join("")
      return [
        [t("驼峰", "駝峰", "camelCase"), camel],
        [t("帕斯卡", "帕斯卡", "PascalCase"), camel[0].toUpperCase() + camel.slice(1)],
        [t("下划线", "底線", "snake_case"), w.join("_")],
        [t("短横线", "連字號", "kebab-case"), w.join("-")],
        [t("全大写", "全大寫", "UPPER CASE"), trimmed.toUpperCase()],
        [t("全小写", "全小寫", "lower case"), trimmed.toLowerCase()],
      ].map(([name, value]) => ({ name, value }))
    },
  },
  {
    id: "hash", glyph: "#=", tint: "teal", cat: CAT.text,
    name: () => t("哈希", "雜湊", "Hashes"),
    hint: () => "MD5、SHA-1、SHA-256",
    placeholder: () => t("输入要算哈希的文字", "輸入要算雜湊的文字", "Text to hash"),
    keys: ["hash", "md5", "sha", "sha1", "sha256", "hx", "哈希"],
    run(text) {
      if (utf8Bytes(text).length > 1 << 17) return [notRecognized(t("太长了，只算 128 KB 以内的", "太長了，只算 128 KB 以內的", "Too long. Up to 128 KB"))]
      return [{ name: "MD5", value: md5(text) }, { name: "SHA-1", value: sha1(text) }, { name: "SHA-256", value: sha256(text) }]
    },
  },
  {
    id: "count", glyph: "12", tint: "teal", cat: CAT.text,
    name: () => t("字数统计", "字數統計", "Character count"),
    hint: () => t("字数、字节数、行数", "字數、位元組數、行數", "Characters, bytes and lines"),
    placeholder: () => t("粘贴要数的文字", "貼上要數的文字", "Paste text to count"),
    keys: ["count", "length", "words", "zs", "tj", "字数"],
    run(text) {
      return [countItem(text)]
    },
  },
]

function availableTools() {
  return TOOLS.filter((tool) => !tool.chineseOnly || LANG === "zh" || LANG === "zh-Hant")
}

/** 名字或关键词对得上的工具（打「jwt」「base64」「时间戳」）。超过 30 个字的不可能是工具名，不用逐个比。 */
function matchingTools(text) {
  const q = text.trim().toLowerCase()
  if (q.length < 2 || q.length > 30) return []
  return availableTools().filter((tool) =>
    tool.name().toLowerCase().includes(q) || tool.keys.some((key) => key.toLowerCase().startsWith(q)))
}

/** 目录里一个工具那一行：生成类直接给值、回车拷贝；别的回车进它那一层。 */
function toolRow(tool, nowMs) {
  const enter = {
    id: "enter", title: t("打开", "打開", "Open"), symbol: "arrow.right.circle.fill", enter: true,
    placeholder: tool.placeholder ? tool.placeholder() : undefined,
    empty: tool.generator ? undefined : tool.hint(),
  }
  const row = {
    id: "tool:" + tool.id,
    title: tool.name(),
    subtitle: tool.cat() + " · " + tool.hint(),
    icon: { text: tool.glyph, tint: tool.tint },
    actions: LEVELS ? [enter] : [],
  }
  if (tool.generator) {
    const value = tool.run("", nowMs)[0].value
    lastValues[row.id] = value
    row.subtitle = tool.cat() + " · " + value
    row.actions = [{ id: "copy", title: t("拷贝", "拷貝", "Copy"), symbol: "doc.on.doc.fill" }]
      .concat(LEVELS ? [{ ...enter, title: t("更多格式", "更多格式", "More formats") }] : [])
  }
  return row
}

/** 最近一次列出来的结果（回车拷贝时按 id 取完整的值：行上的标题会被截短）。 */
let lastValues = {}

/** 结果 → 列表的行（id 按顺序编号，值记进 lastValues）。 */
function resultRows(items, offset = 0) {
  return items.map((item, i) => {
    const id = "r" + (i + offset)
    lastValues[id] = item.value
    const oneLine = item.value.replace(/\s*\n\s*/g, " ⏎ ")
    return {
      id,
      title: oneLine.length > 100 ? oneLine.slice(0, 99) + "…" : oneLine,
      subtitle: item.name,
      icon: item.swatch ? { text: " ", tint: item.swatch }
        : { text: (item.name || "!").slice(0, 1), tint: item.invalid ? "red" : "gray" },
      actions: item.invalid ? [] : [{ id: "copy", title: t("拷贝", "拷貝", "Copy"), symbol: "doc.on.doc.fill" }],
    }
  })
}

/**
 * scope 空（首页）：没输入列全部工具；有输入照旧自动识别，名字对得上的工具排在最前。
 * scope = 工具 id：只列这个工具的结果；没输入时生成类直接给值，别的回空（TabFlick 显示那个工具的说明）。
 */
function list(query, scope, nowMs = Date.now()) {
  lastValues = {}
  const text = String(query == null ? "" : query)
  const toolID = typeof scope === "string" ? scope.replace(/^tool:/, "") : null
  if (toolID) {
    const tool = availableTools().find((x) => x.id === toolID)
    if (!tool || (!text.trim() && !tool.generator)) return []
    return resultRows(tool.run(text, nowMs))
  }
  if (!text.trim()) return availableTools().map((tool) => toolRow(tool, nowMs))
  const tools = matchingTools(text).slice(0, 4).map((tool) => toolRow(tool, nowMs))
  return tools.concat(resultRows(conversions(text, nowMs)))
}

function perform(action, id) {
  if (action !== "copy" || !(id in lastValues)) return
  tabflick.copy(lastValues[id])
  tabflick.toast(t("已拷贝", "已拷貝", "Copied"))
  // 拷走了这个 UUID，下次给新的
  if (lastValues[id] && currentUUID && lastValues[id].toLowerCase().replace(/-/g, "") === currentUUID.replace(/-/g, "")) currentUUID = null
}

if (typeof tabflick !== "undefined" && tabflick.register) {
  tabflick.register({ list, perform })
}
