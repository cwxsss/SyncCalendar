// entry/src/main/ets/common/PlaceParser.ets
// 从剪贴板文本/链接中解析出地点：支持高德分享链接（含坐标）与微信复制的地址文本（无坐标）。
//
// 支持的四种链接形态（均实测过）：
//   ① poi/detail  ?__p=<poiid>,<lat>,<lng>,<name>,<address>      —— 坐标在 query
//   ② share/index  /share/index/__q=<lat>,<lng>,<name>            —— ⚠️ 坐标在 PATH 不在 query
//   ③ place        /place/<poiid>?lng=<lng>&lat=<lat>             —— 显式命名
//   ④ surl 短链    surl.amap.com/<code>                           —— 需跟随 302 取 Location
//
// ⚠️ 坐标系与顺序（最容易搞错的地方）：
//   - 高德所有形态都是「纬度在前、经度在后」，而国内地图复制坐标常是「经度在前」。
//     搞反会定位到几百公里外。本解析器统一用合法范围校验纠偏：
//     纬度绝对值必然 ≤90，若两值都在 90 内则按国旗惯例「纬在前」处理。
//   - 微信/高德输出的都是 GCJ-02（火星坐标），与 Site Kit 一致，**不需要坐标转换**。
//     只有照片 EXIF 的 WGS-84 才需要转，本解析器不处理该场景。
import { http } from '@kit.NetworkKit';
import { LogUtil } from './LogUtil';

/** 解析结果 */
export class ParsedPlace {
  /** 地点名称（可能为空） */
  name: string = '';
  /** 详细地址（可能为空） */
  address: string = '';
  /** 纬度（0 表示无坐标） */
  lat: number = 0;
  /** 经度（0 表示无坐标） */
  lng: number = 0;
  /** 是否有有效坐标 */
  hasCoord: boolean = false;
  /** 命中方式，便于排查：amap-p / amap-q / amap-place / amap-surl / wechat-text / bare-address */
  source: string = '';

  /** 用于填进地点栏的文本：有名称用「名称」，否则用地址 */
  get primaryText(): string {
    return this.name !== '' ? this.name : this.address;
  }
}

export class PlaceParser {
  /** 短链展开超时（毫秒）。网络不好时不值得让用户干等 */
  private static readonly SHORTLINK_TIMEOUT: number = 5000;
  /** 最多跟随几次跳转，防止死循环 */
  private static readonly MAX_REDIRECT: number = 5;

  /**
   * 解析入口：给一段文本，判断是链接还是地址文本，返回地点信息。
   * 无法识别时返回 null（调用方应保持原有输入，不阻塞用户）。
   */
  static async parse(text: string, context?: object): Promise<ParsedPlace | null> {
    const t: string = (text === undefined || text === null) ? '' : text.trim();
    if (t === '') {
      return null;
    }
    // 先尝试按链接解析（含短链展开，需要网络）
    const fromUrl: ParsedPlace | null = await PlaceParser.parseUrl(t);
    if (fromUrl !== null) {
      return fromUrl;
    }
    // 再按纯文本地址解析（无需网络）
    return PlaceParser.parseText(t);
  }

  // ==================== 链接解析 ====================

  private static async parseUrl(text: string): Promise<ParsedPlace | null> {
    // 从可能夹带其他文字的段落里抽出第一个 http(s) 链接
    const urlMatch: RegExpExecArray | null = /https?:\/\/[^\s"'<>）)]+/i.exec(text);
    if (urlMatch === null) {
      return null;
    }
    const url: string = urlMatch[0];
    // ① poi/detail: __p=<id>,<lat>,<lng>,<name>,<address...>
    const p: ParsedPlace | null = PlaceParser.parseAmapP(url);
    if (p !== null) {
      return p;
    }
    // ② share/index: __q=<lat>,<lng>,<name>（在 path 里）
    const q: ParsedPlace | null = PlaceParser.parseAmapQ(url);
    if (q !== null) {
      return q;
    }
    // ③ place: ?lng=&lat=
    const pl: ParsedPlace | null = PlaceParser.parseAmapPlace(url);
    if (pl !== null) {
      return pl;
    }
    // ④ 短链：跟随 302 取 Location 头里的 q 参数
    if (/surl\.amap\.com/i.test(url)) {
      return await PlaceParser.expandShortLink(url);
    }
    return null;
  }

  /**
   * ① `__p=<poiid>,<lat>,<lng>,<name>,<address>`
   *
   * ⚠️ 地址段可能自身含逗号（如「XX路1号,2楼」），所以：
   *    只取前 4 段，第 5 段及之后**全部拼回**地址，避免 split 切错。
   */
  private static parseAmapP(url: string): ParsedPlace | null {
    const m: RegExpExecArray | null = /[?&]__p=([^&]+)/i.exec(url);
    if (m === null) {
      return null;
    }
    let raw: string = '';
    try {
      raw = decodeURIComponent(m[1]);
    } catch (err) {
      return null;
    }
    const segs: string[] = raw.split(',');
    if (segs.length < 3) {
      return null;
    }
    const lat: number = parseFloat(segs[1]);
    const lng: number = parseFloat(segs[2]);
    const out = new ParsedPlace();
    out.source = 'amap-p';
    out.name = segs.length > 3 ? segs[3].trim() : '';
    // 地址 = 第 4 段之后全部拼回（含逗号的情况）
    if (segs.length > 4) {
      out.address = segs.slice(4).join(',').trim();
    }
    const fixed: number[] = PlaceParser.fixLatLng(lat, lng);
    if (fixed[0] !== 0 || fixed[1] !== 0) {
      out.lat = fixed[0];
      out.lng = fixed[1];
      out.hasCoord = true;
    }
    return out.primaryText !== '' ? out : null;
  }

  /**
   * ② `share/index/__q=<lat>,<lng>,<name>`
   *
   * ⚠️ 这是唯一坐标藏在 **path** 而不是 query 里的形态。
   *    只解析 query 会漏掉它，必须先看 path。
   */
  private static parseAmapQ(url: string): ParsedPlace | null {
    const m: RegExpExecArray | null = /__q=([^&]+)/i.exec(url);
    if (m === null) {
      return null;
    }
    let raw: string = '';
    try {
      raw = decodeURIComponent(m[1]);
    } catch (err) {
      return null;
    }
    const segs: string[] = raw.split(',');
    if (segs.length < 2) {
      return null;
    }
    const lat: number = parseFloat(segs[0]);
    const lng: number = parseFloat(segs[1]);
    const out = new ParsedPlace();
    out.source = 'amap-q';
    if (segs.length > 2) {
      out.name = segs.slice(2).join(',').trim();
    }
    const fixed: number[] = PlaceParser.fixLatLng(lat, lng);
    if (fixed[0] !== 0 || fixed[1] !== 0) {
      out.lat = fixed[0];
      out.lng = fixed[1];
      out.hasCoord = true;
    }
    return out.primaryText !== '' ? out : null;
  }

  /** ③ `/place/<poiid>?lng=<lng>&lat=<lat>` —— 显式命名，不存在顺序问题 */
  private static parseAmapPlace(url: string): ParsedPlace | null {
    const mlng: RegExpExecArray | null = /[?&]lng=([-\d.]+)/i.exec(url);
    const mlat: RegExpExecArray | null = /[?&]lat=([-\d.]+)/i.exec(url);
    if (mlng === null || mlat === null) {
      return null;
    }
    const lng: number = parseFloat(mlng[1]);
    const lat: number = parseFloat(mlat[1]);
    const out = new ParsedPlace();
    out.source = 'amap-place';
    const fixed: number[] = PlaceParser.fixLatLng(lat, lng);
    if (fixed[0] === 0 && fixed[1] === 0) {
      return null;
    }
    out.lat = fixed[0];
    out.lng = fixed[1];
    out.hasCoord = true;
    return out;
  }

  /**
   * ④ 短链展开：surl.amap.com/xxx
   *
   * 实测第一次 302 的 Location 就带完整信息：
   *   https://wb.amap.com/?q=32.56132,108.50452,紫阳县明树茶厂
   * 所以不需要跟到底，拿到第一个 Location 即可，省流量也省时间。
   */
  private static async expandShortLink(url: string): Promise<ParsedPlace | null> {
    let cur: string = url;
    for (let i = 0; i < PlaceParser.MAX_REDIRECT; i++) {
      const loc: string = await PlaceParser.headLocation(cur);
      if (loc === '') {
        return null;
      }
      // Location 里可能直接带 q=<lat>,<lng>,<name>
      const m: RegExpExecArray | null = /[?&]q=([^&]+)/i.exec(loc);
      if (m !== null) {
        let raw: string = '';
        try {
          raw = decodeURIComponent(m[1]);
        } catch (err) {
          return null;
        }
        const segs: string[] = raw.split(',');
        if (segs.length >= 2) {
          const lat: number = parseFloat(segs[0]);
          const lng: number = parseFloat(segs[1]);
          const fixed: number[] = PlaceParser.fixLatLng(lat, lng);
          if (fixed[0] !== 0 || fixed[1] !== 0) {
            const out = new ParsedPlace();
            out.source = 'amap-surl';
            out.lat = fixed[0];
            out.lng = fixed[1];
            out.hasCoord = true;
            if (segs.length > 2) {
              out.name = segs.slice(2).join(',').trim();
            }
            return out;
          }
        }
      }
      // 还没到目标，继续跟
      if (!/^https?:/i.test(loc)) {
        return null;
      }
      cur = loc;
      // 中途可能变成 m.amap.com/share/index/__q=... 形态
      const q: ParsedPlace | null = PlaceParser.parseAmapQ(cur);
      if (q !== null) {
        q.source = 'amap-surl';
        return q;
      }
    }
    return null;
  }

  /** 发 HEAD 请求取 Location 头（不下载响应体）。失败返回空串 */
  private static async headLocation(url: string): Promise<string> {
    const req = http.createHttp();
    try {
      const resp: http.HttpResponse = await req.request(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': 'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36' },
        connectTimeout: PlaceParser.SHORTLINK_TIMEOUT,
        readTimeout: PlaceParser.SHORTLINK_TIMEOUT,
        // 关键：不自动跟随跳转，手动读 Location，避免下载整个落地页
        usingProtocol: http.HttpProtocol.HTTP1_1
      });
      const headers = resp.header as Record<string, string>;
      if (headers === undefined || headers === null) {
        return '';
      }
      const loc: string = headers['Location'] ?? headers['location'] ?? '';
      return typeof loc === 'string' ? loc : '';
    } catch (err) {
      LogUtil.write(`短链展开失败: ${url}`);
      return '';
    } finally {
      req.destroy();
    }
  }

  // ==================== 坐标纠偏 ====================

  /**
   * 校正经纬度顺序。
   *
   * 规则（依据实测与地理常识）：
   *  - 纬度绝对值必然 ≤ 90，经度可以到 180
   *  - 若第一个值绝对值 > 90 → 第一个其实是经度，交换
   *  - 若两个都在 90 内 → 按高德惯例「纬在前」，不交换
   *  - 任一为 0 或非数字 → 视为无坐标（返回 [0,0]）
   *
   * @returns [lat, lng]；无效时返回 [0, 0]
   */
  private static fixLatLng(a: number, b: number): number[] {
    const invalid: number[] = [0, 0];
    if (isNaN(a) || isNaN(b) || (a === 0 && b === 0)) {
      return invalid;
    }
    let lat: number = a;
    let lng: number = b;
    if (Math.abs(a) > 90 && Math.abs(b) <= 90) {
      // 第一个是经度，交换
      lat = b;
      lng = a;
    }
    if (Math.abs(lat) > 90 || Math.abs(lng) > 180) {
      return invalid;
    }
    return [lat, lng];
  }

  // ==================== 纯文本地址解析 ====================

  /**
   * 解析微信「复制地址」出来的纯文本。
   *
   * 实测格式：`<名称>(<分店名>) <空格> <省市区+门牌>`
   *   例：招商银行(青岛经济技术开发区支行) 山东省青岛市黄岛区珠江路1-3楼1018号一楼
   *
   * 兼容性考虑：
   *  - 分隔符可能是空格、全角空格、换行
   *  - 括号可能是半角 () 或全角（）
   *  - 可能只有一个名称没有地址
   *  - 可能只有地址没有名称
   *
   * 策略：**名称优先**。因为微信拼的地址可能有问题（实测「珠江路1-3楼1018号」
   * 把楼层塞进了门牌号，检索命中率低），而名称检索几乎必中。
   */
  private static parseText(text: string): ParsedPlace | null {
    // 去掉 URL 残留与多余空白
    let t: string = text.replace(/\s+/g, ' ').trim();
    if (t === '' || t.length < 2) {
      return null;
    }
    const out = new ParsedPlace();
    out.source = 'wechat-text';

    // 情况一：名称(分店) 空格 地址 —— 括号后跟空格是最可靠的切分点
    const m1: RegExpExecArray | null = /^(.+?[)）])\s*(.+)$/.exec(t);
    if (m1 !== null) {
      out.name = m1[1].trim();
      out.address = m1[2].trim();
      return out;
    }
    // 情况二：名称 + 空格 + 行政区开头（省/市/区/县/路/街/号…）
    const m2: RegExpExecArray | null = /^(.+?)\s+((?:中国)?[省市区县].+)$/.exec(t);
    if (m2 !== null) {
      out.name = m2[1].trim();
      out.address = m2[2].trim();
      return out;
    }
    // 情况三：只有名称，或只有地址
    if (/^(?:中国)?[省市区县]/.test(t) || /[路街号弄巷栋楼室]/.test(t)) {
      out.address = t;
    } else {
      out.name = t;
    }
    return out.primaryText !== '' ? out : null;
  }

  // ==================== 工具 ====================

  /** 反向地理编码后的展示文本：名称 | 地址 */
  static mergeForLocationText(name: string, address: string): string {
    if (name !== '' && address !== '' && name !== address) {
      return `${name}｜${address}`;
    }
    return name !== '' ? name : address;
  }
}