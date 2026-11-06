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
  // JWT：载荷、头、过期时间（不验签名）
  const jwt = decodeJWT(trimmed)
  if (jwt) {
    out.push({ name: t("JWT 载荷", "JWT 載荷", "JWT payload"), value: JSON.stringify(jwt.payload, null, 2) })
    out.push({ name: t("JWT 头", "JWT 標頭", "JWT header"), value: JSON.stringify(jwt.header, null, 2) })
    if (typeof jwt.payload.exp === "number") {
      out.push({ name: t("JWT 过期时间", "JWT 過期時間", "JWT expires") + " · " + relative(jwt.payload.exp * 1000, nowMs),
                 value: localDate(jwt.payload.exp * 1000) })
    }
    if (typeof jwt.payload.iat === "number") {
      out.push({ name: t("JWT 签发时间", "JWT 簽發時間", "JWT issued"), value: localDate(jwt.payload.iat * 1000) })
    }
  }
  // 时间戳 → 日期：10 位秒、13 位毫秒
  if (/^\d{10}$|^\d{13}$/.test(trimmed)) {
    const ms = trimmed.length === 10 ? parseInt(trimmed, 10) * 1000 : parseInt(trimmed, 10)
    out.push({ name: t("时间戳 → 本地时间", "時間戳 → 本地時間", "Timestamp → local time"), value: localDate(ms) })
    out.push({ name: t("时间戳 → ISO（UTC）", "時間戳 → ISO（UTC）", "Timestamp → ISO (UTC)"), value: new Date(ms).toISOString() })
  }
  // 日期 → 时间戳：认得出的日期写法（2026-11-06、2026/11/06 18:30、ISO）
  if (/\d{4}[-/]\d{1,2}[-/]\d{1,2}/.test(trimmed)) {
    const ms = Date.parse(trimmed.replace(/\//g, "-").replace(" ", "T"))
    if (isFinite(ms)) {
      out.push({ name: t("日期 → 时间戳（秒）", "日期 → 時間戳（秒）", "Date → timestamp (s)"), value: String(Math.floor(ms / 1000)) })
      out.push({ name: t("日期 → 时间戳（毫秒）", "日期 → 時間戳（毫秒）", "Date → timestamp (ms)"), value: String(ms) })
    }
  }
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
  const lines = text.split("\n").length
  out.push({
    name: t("字数", "字數", "Length"),
    value: t(`${[...text].length} 个字 · ${bytes} 字节 · ${lines} 行`, `${[...text].length} 個字 · ${bytes} 位元組 · ${lines} 行`,
             `${[...text].length} chars · ${bytes} bytes · ${lines} lines`),
    stat: true,
  })
  return out
}

/** 最近一次列出来的结果（回车拷贝时按 id 取完整的值：行上的标题会被截短）。 */
let lastValues = {}

function list(query) {
  const items = conversions(query)
  lastValues = {}
  return items.map((item, i) => {
    const id = "r" + i
    lastValues[id] = item.value
    const oneLine = item.value.replace(/\s*\n\s*/g, " ⏎ ")
    return {
      id,
      title: oneLine.length > 100 ? oneLine.slice(0, 99) + "…" : oneLine,
      subtitle: item.name,
      icon: item.swatch ? { text: " ", tint: item.swatch } : { text: item.name.slice(0, 1), tint: item.invalid ? "red" : "gray" },
      actions: item.invalid ? [] : [{ id: "copy", title: t("拷贝", "拷貝", "Copy"), symbol: "doc.on.doc.fill" }],
    }
  })
}

function perform(action, id) {
  if (action !== "copy" || !(id in lastValues)) return
  tabflick.copy(lastValues[id])
  tabflick.toast(t("已拷贝", "已拷貝", "Copied"))
}

if (typeof tabflick !== "undefined" && tabflick.register) {
  tabflick.register({ list, perform })
}
