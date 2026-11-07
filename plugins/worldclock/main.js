// TabFlick 世界时钟插件（官方）。不联网：内置一份城市 → 时区表，时间用 Intl.DateTimeFormat 按时区算（夏令时自动对）。

const LANG = (typeof tabflick !== "undefined" && tabflick.locale) || "en"
function t(zh, hant, en) {
  if (LANG === "zh") return zh
  if (LANG === "zh-Hant") return hant
  return en
}

/** [id, 中文名, 繁中名, 英文名, 时区, 国家, 拼音首字母]。id 是存盘的键，别改（老版本存的 delhi 等照旧认）。 */
const CITIES = [
  ["beijing", "北京", "北京", "Beijing", "Asia/Shanghai", "cn", "bj"],
  ["shanghai", "上海", "上海", "Shanghai", "Asia/Shanghai", "cn", "sh"],
  ["guangzhou", "广州", "廣州", "Guangzhou", "Asia/Shanghai", "cn", "gz"],
  ["shenzhen", "深圳", "深圳", "Shenzhen", "Asia/Shanghai", "cn", "sz"],
  ["chengdu", "成都", "成都", "Chengdu", "Asia/Shanghai", "cn", "cd"],
  ["hangzhou", "杭州", "杭州", "Hangzhou", "Asia/Shanghai", "cn", "hz"],
  ["wuhan", "武汉", "武漢", "Wuhan", "Asia/Shanghai", "cn", "wh"],
  ["xian", "西安", "西安", "Xi'an", "Asia/Shanghai", "cn", "xa"],
  ["chongqing", "重庆", "重慶", "Chongqing", "Asia/Shanghai", "cn", "cq"],
  ["hongkong", "香港", "香港", "Hong Kong", "Asia/Hong_Kong", "hk", "xg"],
  ["macau", "澳门", "澳門", "Macau", "Asia/Macau", "mo", "am"],
  ["taipei", "台北", "臺北", "Taipei", "Asia/Taipei", "tw", "tb"],
  ["tokyo", "东京", "東京", "Tokyo", "Asia/Tokyo", "jp", "dj"],
  ["osaka", "大阪", "大阪", "Osaka", "Asia/Tokyo", "jp", "db"],
  ["seoul", "首尔", "首爾", "Seoul", "Asia/Seoul", "kr", "se"],
  ["busan", "釜山", "釜山", "Busan", "Asia/Seoul", "kr", "fs"],
  ["singapore", "新加坡", "新加坡", "Singapore", "Asia/Singapore", "sg", "xjp"],
  ["bangkok", "曼谷", "曼谷", "Bangkok", "Asia/Bangkok", "th", "mg"],
  ["phuket", "普吉", "普吉", "Phuket", "Asia/Bangkok", "th", "pj"],
  ["hanoi", "河内", "河內", "Hanoi", "Asia/Ho_Chi_Minh", "vn", "hn"],
  ["hochiminh", "胡志明市", "胡志明市", "Ho Chi Minh City", "Asia/Ho_Chi_Minh", "vn", "hzms"],
  ["kualalumpur", "吉隆坡", "吉隆坡", "Kuala Lumpur", "Asia/Kuala_Lumpur", "my", "jlp"],
  ["jakarta", "雅加达", "雅加達", "Jakarta", "Asia/Jakarta", "id", "yjd"],
  ["bali", "巴厘岛", "峇里島", "Bali", "Asia/Makassar", "id", "bld"],
  ["manila", "马尼拉", "馬尼拉", "Manila", "Asia/Manila", "ph", "mnl"],
  ["delhi", "新德里", "新德里", "New Delhi", "Asia/Kolkata", "in", "xdl"],
  ["mumbai", "孟买", "孟買", "Mumbai", "Asia/Kolkata", "in", "mm"],
  ["bangalore", "班加罗尔", "班加羅爾", "Bangalore", "Asia/Kolkata", "in", "bjle"],
  ["karachi", "卡拉奇", "卡拉奇", "Karachi", "Asia/Karachi", "pk", "klq"],
  ["dhaka", "达卡", "達卡", "Dhaka", "Asia/Dhaka", "bd", "dk"],
  ["kathmandu", "加德满都", "加德滿都", "Kathmandu", "Asia/Kathmandu", "np", "jdmd"],
  ["colombo", "科伦坡", "可倫坡", "Colombo", "Asia/Colombo", "lk", "klp"],
  ["dubai", "迪拜", "杜拜", "Dubai", "Asia/Dubai", "ae", "db"],
  ["abudhabi", "阿布扎比", "阿布達比", "Abu Dhabi", "Asia/Dubai", "ae", "abzb"],
  ["riyadh", "利雅得", "利雅德", "Riyadh", "Asia/Riyadh", "sa", "lyd"],
  ["doha", "多哈", "杜哈", "Doha", "Asia/Qatar", "qa", "dh"],
  ["telaviv", "特拉维夫", "特拉維夫", "Tel Aviv", "Asia/Jerusalem", "il", "tlwf"],
  ["tehran", "德黑兰", "德黑蘭", "Tehran", "Asia/Tehran", "ir", "dhl"],
  ["istanbul", "伊斯坦布尔", "伊斯坦堡", "Istanbul", "Europe/Istanbul", "tr", "ystbe"],
  ["moscow", "莫斯科", "莫斯科", "Moscow", "Europe/Moscow", "ru", "msk"],
  ["stpetersburg", "圣彼得堡", "聖彼得堡", "Saint Petersburg", "Europe/Moscow", "ru", "sbdb"],
  ["novosibirsk", "新西伯利亚", "新西伯利亞", "Novosibirsk", "Asia/Novosibirsk", "ru", "xxbly"],
  ["vladivostok", "符拉迪沃斯托克", "海參崴", "Vladivostok", "Asia/Vladivostok", "ru", "fldwstk"],
  ["london", "伦敦", "倫敦", "London", "Europe/London", "gb", "ld"],
  ["manchester", "曼彻斯特", "曼徹斯特", "Manchester", "Europe/London", "gb", "mcst"],
  ["edinburgh", "爱丁堡", "愛丁堡", "Edinburgh", "Europe/London", "gb", "adb"],
  ["dublin", "都柏林", "都柏林", "Dublin", "Europe/Dublin", "ie", "dbl"],
  ["paris", "巴黎", "巴黎", "Paris", "Europe/Paris", "fr", "bl"],
  ["lyon", "里昂", "里昂", "Lyon", "Europe/Paris", "fr", "la"],
  ["nice", "尼斯", "尼斯", "Nice", "Europe/Paris", "fr", "ns"],
  ["berlin", "柏林", "柏林", "Berlin", "Europe/Berlin", "de", "bl"],
  ["munich", "慕尼黑", "慕尼黑", "Munich", "Europe/Berlin", "de", "mnh"],
  ["frankfurt", "法兰克福", "法蘭克福", "Frankfurt", "Europe/Berlin", "de", "flkf"],
  ["amsterdam", "阿姆斯特丹", "阿姆斯特丹", "Amsterdam", "Europe/Amsterdam", "nl", "amstd"],
  ["brussels", "布鲁塞尔", "布魯塞爾", "Brussels", "Europe/Brussels", "be", "blse"],
  ["zurich", "苏黎世", "蘇黎世", "Zurich", "Europe/Zurich", "ch", "sls"],
  ["geneva", "日内瓦", "日內瓦", "Geneva", "Europe/Zurich", "ch", "rnw"],
  ["vienna", "维也纳", "維也納", "Vienna", "Europe/Vienna", "at", "wyn"],
  ["rome", "罗马", "羅馬", "Rome", "Europe/Rome", "it", "lm"],
  ["milan", "米兰", "米蘭", "Milan", "Europe/Rome", "it", "ml"],
  ["madrid", "马德里", "馬德里", "Madrid", "Europe/Madrid", "es", "mdl"],
  ["barcelona", "巴塞罗那", "巴塞隆納", "Barcelona", "Europe/Madrid", "es", "bsln"],
  ["lisbon", "里斯本", "里斯本", "Lisbon", "Europe/Lisbon", "pt", "lsb"],
  ["stockholm", "斯德哥尔摩", "斯德哥爾摩", "Stockholm", "Europe/Stockholm", "se", "sdgem"],
  ["oslo", "奥斯陆", "奧斯陸", "Oslo", "Europe/Oslo", "no", "asl"],
  ["copenhagen", "哥本哈根", "哥本哈根", "Copenhagen", "Europe/Copenhagen", "dk", "gbhg"],
  ["helsinki", "赫尔辛基", "赫爾辛基", "Helsinki", "Europe/Helsinki", "fi", "hexj"],
  ["warsaw", "华沙", "華沙", "Warsaw", "Europe/Warsaw", "pl", "hs"],
  ["prague", "布拉格", "布拉格", "Prague", "Europe/Prague", "cz", "blg"],
  ["athens", "雅典", "雅典", "Athens", "Europe/Athens", "gr", "yd"],
  ["budapest", "布达佩斯", "布達佩斯", "Budapest", "Europe/Budapest", "hu", "bdps"],
  ["kyiv", "基辅", "基輔", "Kyiv", "Europe/Kiev", "ua", "jf"],
  ["cairo", "开罗", "開羅", "Cairo", "Africa/Cairo", "eg", "kl"],
  ["johannesburg", "约翰内斯堡", "約翰尼斯堡", "Johannesburg", "Africa/Johannesburg", "za", "yhnsb"],
  ["capetown", "开普敦", "開普敦", "Cape Town", "Africa/Johannesburg", "za", "kpd"],
  ["lagos", "拉各斯", "拉哥斯", "Lagos", "Africa/Lagos", "ng", "lgs"],
  ["nairobi", "内罗毕", "奈洛比", "Nairobi", "Africa/Nairobi", "ke", "nlb"],
  ["casablanca", "卡萨布兰卡", "卡薩布蘭卡", "Casablanca", "Africa/Casablanca", "ma", "ksblk"],
  ["newyork", "纽约", "紐約", "New York", "America/New_York", "us", "ny"],
  ["washington", "华盛顿", "華盛頓", "Washington", "America/New_York", "us", "hsd"],
  ["boston", "波士顿", "波士頓", "Boston", "America/New_York", "us", "bsd"],
  ["miami", "迈阿密", "邁阿密", "Miami", "America/New_York", "us", "mam"],
  ["atlanta", "亚特兰大", "亞特蘭大", "Atlanta", "America/New_York", "us", "ytld"],
  ["chicago", "芝加哥", "芝加哥", "Chicago", "America/Chicago", "us", "zjg"],
  ["houston", "休斯敦", "休士頓", "Houston", "America/Chicago", "us", "xsd"],
  ["dallas", "达拉斯", "達拉斯", "Dallas", "America/Chicago", "us", "dls"],
  ["denver", "丹佛", "丹佛", "Denver", "America/Denver", "us", "df"],
  ["phoenix", "菲尼克斯", "鳳凰城", "Phoenix", "America/Phoenix", "us", "fnks"],
  ["losangeles", "洛杉矶", "洛杉磯", "Los Angeles", "America/Los_Angeles", "us", "lsj"],
  ["sanfrancisco", "旧金山", "舊金山", "San Francisco", "America/Los_Angeles", "us", "jjs"],
  ["seattle", "西雅图", "西雅圖", "Seattle", "America/Los_Angeles", "us", "xyt"],
  ["lasvegas", "拉斯维加斯", "拉斯維加斯", "Las Vegas", "America/Los_Angeles", "us", "lswjs"],
  ["anchorage", "安克雷奇", "安克拉治", "Anchorage", "America/Anchorage", "us", "aklq"],
  ["honolulu", "檀香山", "檀香山", "Honolulu", "Pacific/Honolulu", "us", "txs"],
  ["toronto", "多伦多", "多倫多", "Toronto", "America/Toronto", "ca", "dld"],
  ["ottawa", "渥太华", "渥太華", "Ottawa", "America/Toronto", "ca", "wth"],
  ["montreal", "蒙特利尔", "蒙特婁", "Montreal", "America/Toronto", "ca", "mtle"],
  ["vancouver", "温哥华", "溫哥華", "Vancouver", "America/Vancouver", "ca", "wgh"],
  ["calgary", "卡尔加里", "卡加利", "Calgary", "America/Edmonton", "ca", "kejl"],
  ["edmonton", "埃德蒙顿", "愛民頓", "Edmonton", "America/Edmonton", "ca", "admd"],
  ["winnipeg", "温尼伯", "溫尼伯", "Winnipeg", "America/Winnipeg", "ca", "wnb"],
  ["halifax", "哈利法克斯", "哈利法克斯", "Halifax", "America/Halifax", "ca", "hlfks"],
  ["stjohns", "圣约翰斯", "聖約翰斯", "St. John's", "America/St_Johns", "ca", "syhs"],
  ["mexicocity", "墨西哥城", "墨西哥城", "Mexico City", "America/Mexico_City", "mx", "mxgc"],
  ["cancun", "坎昆", "坎昆", "Cancun", "America/Cancun", "mx", "kk"],
  ["saopaulo", "圣保罗", "聖保羅", "São Paulo", "America/Sao_Paulo", "br", "sbl"],
  ["riodejaneiro", "里约热内卢", "里約熱內盧", "Rio de Janeiro", "America/Sao_Paulo", "br", "lyrnl"],
  ["manaus", "马瑙斯", "馬瑙斯", "Manaus", "America/Manaus", "br", "mns"],
  ["buenosaires", "布宜诺斯艾利斯", "布宜諾斯艾利斯", "Buenos Aires", "America/Argentina/Buenos_Aires", "ar", "bynsals"],
  ["santiago", "圣地亚哥", "聖地牙哥", "Santiago", "America/Santiago", "cl", "sdyg"],
  ["lima", "利马", "利馬", "Lima", "America/Lima", "pe", "lm"],
  ["bogota", "波哥大", "波哥大", "Bogotá", "America/Bogota", "co", "bgd"],
  ["sydney", "悉尼", "雪梨", "Sydney", "Australia/Sydney", "au", "xn"],
  ["melbourne", "墨尔本", "墨爾本", "Melbourne", "Australia/Melbourne", "au", "meb"],
  ["brisbane", "布里斯班", "布里斯本", "Brisbane", "Australia/Brisbane", "au", "blsb"],
  ["perth", "珀斯", "伯斯", "Perth", "Australia/Perth", "au", "ps"],
  ["adelaide", "阿德莱德", "阿德雷德", "Adelaide", "Australia/Adelaide", "au", "adld"],
  ["darwin", "达尔文", "達爾文", "Darwin", "Australia/Darwin", "au", "dew"],
  ["auckland", "奥克兰", "奧克蘭", "Auckland", "Pacific/Auckland", "nz", "akl"],
  ["wellington", "惠灵顿", "威靈頓", "Wellington", "Pacific/Auckland", "nz", "hld"],
  ["utc", "UTC", "UTC", "UTC", "UTC", "utc", "utc"],
];
const BY_ID = Object.fromEntries(CITIES.map((c) => [c[0], c]))

/** 国家 / 地区：[中文, 繁中, 英文, 别名（含拼音首字母）]。搜到国家就列出它所有的城市。 */
const COUNTRIES = {
  "cn": ["中国", "中國", "China", ["prc", "zg"]],
  "hk": ["中国香港", "中國香港", "Hong Kong", ["香港", "zgxg"]],
  "mo": ["中国澳门", "中國澳門", "Macau", ["澳门", "澳門", "zgam"]],
  "tw": ["中国台湾", "台灣", "Taiwan", ["台湾", "zgtw"]],
  "jp": ["日本", "日本", "Japan", ["rb"]],
  "kr": ["韩国", "韓國", "South Korea", ["korea", "hg"]],
  "sg": ["新加坡", "新加坡", "Singapore", ["xjp"]],
  "th": ["泰国", "泰國", "Thailand", ["tg"]],
  "vn": ["越南", "越南", "Vietnam", ["yn"]],
  "my": ["马来西亚", "馬來西亞", "Malaysia", ["mlxy"]],
  "id": ["印度尼西亚", "印尼", "Indonesia", ["印尼", "ydnxy"]],
  "ph": ["菲律宾", "菲律賓", "Philippines", ["flb"]],
  "in": ["印度", "印度", "India", ["yd"]],
  "pk": ["巴基斯坦", "巴基斯坦", "Pakistan", ["bjst"]],
  "bd": ["孟加拉国", "孟加拉", "Bangladesh", ["孟加拉", "mjlg"]],
  "np": ["尼泊尔", "尼泊爾", "Nepal", ["npe"]],
  "lk": ["斯里兰卡", "斯里蘭卡", "Sri Lanka", ["sllk"]],
  "ae": ["阿联酋", "阿聯酋", "United Arab Emirates", ["uae", "阿拉伯联合酋长国", "alq"]],
  "sa": ["沙特阿拉伯", "沙烏地阿拉伯", "Saudi Arabia", ["沙特", "stalb"]],
  "qa": ["卡塔尔", "卡達", "Qatar", ["kte"]],
  "il": ["以色列", "以色列", "Israel", ["ysl"]],
  "ir": ["伊朗", "伊朗", "Iran", ["yl"]],
  "tr": ["土耳其", "土耳其", "Turkey", ["türkiye", "teq"]],
  "ru": ["俄罗斯", "俄羅斯", "Russia", ["els"]],
  "gb": ["英国", "英國", "United Kingdom", ["uk", "britain", "england", "yg"]],
  "ie": ["爱尔兰", "愛爾蘭", "Ireland", ["ael"]],
  "fr": ["法国", "法國", "France", ["fg"]],
  "de": ["德国", "德國", "Germany", ["dg"]],
  "nl": ["荷兰", "荷蘭", "Netherlands", ["holland", "hl"]],
  "be": ["比利时", "比利時", "Belgium", ["bls"]],
  "ch": ["瑞士", "瑞士", "Switzerland", ["rs"]],
  "at": ["奥地利", "奧地利", "Austria", ["adl"]],
  "it": ["意大利", "義大利", "Italy", ["义大利", "ydl"]],
  "es": ["西班牙", "西班牙", "Spain", ["xby"]],
  "pt": ["葡萄牙", "葡萄牙", "Portugal", ["pty"]],
  "se": ["瑞典", "瑞典", "Sweden", ["rd"]],
  "no": ["挪威", "挪威", "Norway", ["nw"]],
  "dk": ["丹麦", "丹麥", "Denmark", ["dm"]],
  "fi": ["芬兰", "芬蘭", "Finland", ["fl"]],
  "pl": ["波兰", "波蘭", "Poland", ["bl"]],
  "cz": ["捷克", "捷克", "Czechia", ["czech republic", "jk"]],
  "gr": ["希腊", "希臘", "Greece", ["xl"]],
  "hu": ["匈牙利", "匈牙利", "Hungary", ["xyl"]],
  "ua": ["乌克兰", "烏克蘭", "Ukraine", ["wkl"]],
  "eg": ["埃及", "埃及", "Egypt", ["aj"]],
  "za": ["南非", "南非", "South Africa", ["nf"]],
  "ng": ["尼日利亚", "奈及利亞", "Nigeria", ["nrly"]],
  "ke": ["肯尼亚", "肯亞", "Kenya", ["kny"]],
  "ma": ["摩洛哥", "摩洛哥", "Morocco", ["mlg"]],
  "us": ["美国", "美國", "United States", ["usa", "america", "us", "mg"]],
  "ca": ["加拿大", "加拿大", "Canada", ["jnd"]],
  "mx": ["墨西哥", "墨西哥", "Mexico", ["mxg"]],
  "br": ["巴西", "巴西", "Brazil", ["bx"]],
  "ar": ["阿根廷", "阿根廷", "Argentina", ["agt"]],
  "cl": ["智利", "智利", "Chile", ["zl"]],
  "pe": ["秘鲁", "秘魯", "Peru", ["bl"]],
  "co": ["哥伦比亚", "哥倫比亞", "Colombia", ["glby"]],
  "au": ["澳大利亚", "澳洲", "Australia", ["澳洲", "adly"]],
  "nz": ["新西兰", "紐西蘭", "New Zealand", ["纽西兰", "xxl"]],
  "utc": ["协调世界时", "協調世界時", "UTC", ["gmt", "世界时"]],
}

function cityByID(id) {
  return BY_ID[id]
}

function cityName(c) {
  return t(c[1], c[2], c[3])
}

/** 默认收藏：纽约、伦敦。 */
function saved() {
  const s = tabflick.storage.get("cities")
  return (Array.isArray(s) ? s : ["newyork", "london"]).filter((id) => BY_ID[id])
}

/** 某个时区此刻的墙上时间：{ y, m, d, hour, minute }。 */
function wallTime(tz, nowMs) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: tz, hourCycle: "h23", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
  }).formatToParts(new Date(nowMs))
  const get = (type) => parseInt(parts.find((p) => p.type === type).value, 10)
  return { y: get("year"), m: get("month"), d: get("day"), hour: get("hour"), minute: get("minute") }
}

/** 时区相对 UTC 偏多少分钟（夏令时按此刻算）。 */
function offsetMinutes(tz, nowMs) {
  const w = wallTime(tz, nowMs)
  const asUTC = Date.UTC(w.y, w.m - 1, w.d, w.hour, w.minute)
  return Math.round((asUTC - Math.floor(nowMs / 60000) * 60000) / 60000)
}

/** 一个城市此刻：时间、和本地差多少、是本地的昨天 / 今天 / 明天。localOffset 是本地相对 UTC 的分钟。 */
function clock(c, nowMs, localOffset) {
  const w = wallTime(c[4], nowMs)
  const diff = offsetMinutes(c[4], nowMs) - localOffset
  const pad = (n) => String(n).padStart(2, "0")
  const localDay = new Date(nowMs + localOffset * 60000).getUTCDate()
  const dayDiff = w.d === localDay ? 0 : (diff > 0 ? 1 : -1)
  return { time: `${pad(w.hour)}:${pad(w.minute)}`, diff, dayDiff }
}

function describeDiff(diff) {
  if (diff === 0) return t("和本地相同", "和本地相同", "Same as local")
  const h = Math.abs(diff) / 60
  const text = Number.isInteger(h) ? String(h) : h.toFixed(1)
  return diff > 0 ? t(`比本地早 ${text} 小时`, `比本地早 ${text} 小時`, `${text}h ahead`)
                  : t(`比本地晚 ${text} 小时`, `比本地晚 ${text} 小時`, `${text}h behind`)
}

function describeDay(dayDiff) {
  if (dayDiff > 0) return t("明天", "明天", "Tomorrow")
  if (dayDiff < 0) return t("昨天", "昨天", "Yesterday")
  return t("今天", "今天", "Today")
}

function localOffsetNow(nowMs) {
  return -new Date(nowMs).getTimezoneOffset()
}

const isCJK = (s) => /[\u3400-\u9fff]/.test(s)

/** 名字和输入比：一样 / 开头 / 包含 / 输入里含着名字（「多伦多市」「纽约时间」）。英文只认词头和整词。 */
function nameScore(names, q, exact, prefix, contains, inside) {
  let best = 0
  for (const raw of names) {
    const n = raw.toLowerCase()
    if (!n) continue
    if (n === q) return exact
    if (n.startsWith(q)) best = Math.max(best, prefix)
    else if (isCJK(q) ? n.includes(q) : (" " + n).includes(" " + q)) best = Math.max(best, contains)
    else if (n.length >= 2 && (isCJK(n) ? q.includes(n) : (" " + q + " ").includes(" " + n + " "))) best = Math.max(best, inside)
  }
  return best
}

/** 一个城市对输入的得分，0 = 不算命中。城市自己的名字优先；国家命中时这个国家的城市全列，排在城市名命中之后。 */
function score(c, q) {
  const compact = q.replace(/\s+/g, "")
  let s = nameScore([c[1], c[2], c[3]], q, 100, 90, 70, 65)
  if (/^[a-z]+$/.test(compact) && (c[6].startsWith(compact) || c[0].startsWith(compact))) s = Math.max(s, 80)
  const country = COUNTRIES[c[5]]
  if (country) s = Math.max(s, nameScore([country[0], country[1], country[2]].concat(country[3]), q, 60, 55, 50, 45))
  // 时区名按段认开头（america、kolkata、asia/tokyo），不认中间的字母：jerusalem 里也有 usa
  if (q.length >= 3) {
    const tz = c[4].toLowerCase().replace(/_/g, " ")
    if (tz.startsWith(q) || tz.split("/").some((part) => part.startsWith(q))) s = Math.max(s, 30)
  }
  return s
}

function countryName(c) {
  const country = COUNTRIES[c[5]]
  return country ? t(country[0], country[1], country[2]) : ""
}

function cityRow(c, nowMs, localOffset, isSaved) {
  const k = clock(c, nowMs, localOffset)
  return {
    id: c[0],
    title: cityName(c),
    subtitle: [countryName(c), describeDiff(k.diff)].concat(k.dayDiff ? [describeDay(k.dayDiff)] : []).filter(Boolean).join(" · "),
    value: k.time,
    // TabFlick 按这个时区自己画「时:分:秒」、每秒走一下（不用每秒调插件）；不认它的老版本照旧显示 value
    clock: c[4],
    icon: { text: cityName(c).slice(0, 1), tint: "indigo" },
    actions: isSaved
      ? [{ id: "copy", title: t("拷贝时间", "拷貝時間", "Copy Time"), symbol: "doc.on.doc.fill" },
         { id: "remove", title: t("移出", "移出", "Remove"), symbol: "minus.circle.fill", destructive: true, stay: true }]
      : [{ id: "add", title: t("加入", "加入", "Add"), symbol: "plus.circle.fill", stay: true, clear: true },
         { id: "copy", title: t("拷贝时间", "拷貝時間", "Copy Time"), symbol: "doc.on.doc.fill" }],
  }
}

function list(query, nowMs = Date.now()) {
  const local = localOffsetNow(nowMs)
  const mine = saved()
  const text = String(query || "").trim()
  if (!text) return mine.map((id) => cityRow(BY_ID[id], nowMs, local, true))
  const q = text.toLowerCase()
  const hits = []
  CITIES.forEach((c, order) => {
    const s = score(c, q)
    if (s > 0) hits.push({ c, s, saved: mine.includes(c[0]), order })
  })
  hits.sort((a, b) => b.s - a.s || (b.saved ? 1 : 0) - (a.saved ? 1 : 0) || a.order - b.order)
  return hits.slice(0, 40).map((h) => cityRow(h.c, nowMs, local, h.saved))
}

function perform(action, id, nowMs = Date.now()) {
  const c = BY_ID[id]
  if (!c) return
  const mine = saved()
  if (action === "add" && !mine.includes(id)) {
    tabflick.storage.set("cities", mine.concat([id]))
    tabflick.toast(t("已添加城市", "已新增城市", "City added"), cityName(c))
  }
  else if (action === "remove") tabflick.storage.set("cities", mine.filter((x) => x !== id))
  else if (action === "copy") {
    const k = clock(c, nowMs, localOffsetNow(nowMs))
    tabflick.copy(`${cityName(c)} ${k.time}`)
    tabflick.toast(t("已拷贝时间", "已拷貝時間", "Time copied"), `${cityName(c)} ${k.time}`)
  }
}

function menu(nowMs = Date.now()) {
  const local = localOffsetNow(nowMs)
  const mine = saved()
  if (!mine.length) return [{ type: "note", text: t("还没有城市", "還沒有城市", "No cities yet") }]
  return mine.map((id) => {
    const c = BY_ID[id]
    const k = clock(c, nowMs, local)
    return { title: cityName(c), value: k.time, detail: describeDiff(k.diff) + (k.dayDiff ? " · " + describeDay(k.dayDiff) : ""), symbol: "clock.fill", action: "copy:" + id }
  })
}

if (typeof tabflick !== "undefined" && tabflick.register) {
  tabflick.register({
    menu: () => menu(),
    list: (q) => list(q),
    perform: (a, id) => perform(a, id),
    action(id) {
      const m = /^copy:([a-z]+)$/.exec(String(id))
      if (m) perform("copy", m[1])
    },
  })
}
