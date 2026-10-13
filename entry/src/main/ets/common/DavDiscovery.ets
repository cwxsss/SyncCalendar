// entry/src/main/ets/common/DavDiscovery.ets
// ⭐ CalDAV 地址自动发现与智能补全（0.0.7）
//
// 解决的用户问题（见《CalDAV排查指南-405与读不出日历.md》）：
//   用户习惯只填域名或 DAV 根，而 Nextcloud 等要求填「日历家目录」
//   （/remote.php/dav/calendars/<用户名>/）。填错表现为"读不出日历"或 405。
//   DAVx5 能用是因为它内置 .well-known 自动发现 —— 本模块补上这一能力。
//
// 发现顺序（逐级降级，任一成功即停）：
//   ① 用户填的地址原样探测（保持既有行为，兼容已能用的用户）
//   ② .well-known/caldav（RFC 6764 标准；Nextcloud/Radicale/Baïkal 均支持）
//   ③ 常见候选路径拼接（remote.php/dav/calendars/<用户名>/ 等）
//
// ⚠️ 设计约束：
//  - 全部探测都是 PROPFIND + Depth:0，只判断「是不是能列出日历的端点」，不做副作用；
//  - 单次探测失败不抛错（网络异常吞掉继续试下一个），保证不会因某个候选不可达而整体失败；
//  - 最终由调用方用 listCalendars 校验（能列出 calendar 集合才算真成功）。
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogUtil } from './LogUtil';

/** 发现结果：拿到一个可用的"日历集合列表"端点 */
export class DiscoverResult {
  ok: boolean = false;
  url: string = '';          // 最终可用的端点 URL
  via: string = '';          // 来源：direct / well-known / candidate / public
  readOnly: boolean = false; // 是否只读（公开日历分享）；本版本仅识别，不做写入
  hint: string = '';         // 失败时给用户的可操作提示
}

/** 415/405 之外：用于判断"不是 DAV 端点"的状态码集合 */
const NOT_DAV_CODES: number[] = [404, 405, 501];

export class DavDiscovery {
  // ───────────────────────── 公开工具：URL 形态识别 ─────────────────────────

  /** 取 origin（scheme://host[:port]） */
  static originOf(url: string): string {
    const m = /^https?:\/\/[^/]+/i.exec(url.trim());
    return m !== null ? m[0] : '';
  }

  /** 规范化：去掉末尾多余斜杠、去空白 */
  static tidy(url: string): string {
    let s: string = url.trim();
    // 去掉查询与片段（发现阶段不保留）
    s = s.replace(/[?#].*$/, '');
    while (s.endsWith('/') && s.length > DavDiscovery.originOf(s).length + 1) {
      s = s.substring(0, s.length - 1);
    }
    return s;
  }

  /**
   * ⭐ 识别「网页分享链接」——这类地址对 PROPFIND 一律 405，必须提前拦下并提示。
   * 覆盖：
   *  - Nextcloud 日历分享页：/apps/calendar/p/<token>
   *  - Nextcloud 文件分享页：/s/<token>、/index.php/s/<token>
   *  - Nextcloud 公开日历（只读，可用）：/remote.php/dav/public-calendars/<token>
   */
  static classify(url: string): string {
    const u: string = url.trim();
    const path = u.replace(/^https?:\/\/[^/]+/i, '');
    if (/^\/apps\/calendar\/p\//i.test(path)) {
      return 'share_calendar';       // 日历分享页面（网页）
    }
    if (/^\/(index\.php\/)?s\//i.test(path)) {
      return 'share_file';           // 文件分享页面（网页）
    }
    if (/^\/remote\.php\/dav\/public-calendars\//i.test(path)) {
      return 'public_caldav';        // 公开日历（DAV，只读）
    }
    if (/^\/remote\.php\/dav\/public-calendars$/i.test(path.replace(/\/$/, ''))) {
      return 'public_caldav';
    }
    return 'normal';
  }

  /** 分享链接 → 给用户的人话解释 */
  static shareHint(kind: string): string {
    if (kind === 'share_calendar') {
      return '这是 Nextcloud 的「日历分享链接」（网页地址），CalDAV 客户端不能直接使用。'
        + '请在 Nextcloud 网页版「日历 → 左下角设置 → 目标日历 → 复制私有链接」，'
        + '把得到的私有链接填到「服务器地址」。';
    }
    if (kind === 'share_file') {
      return '这是文件分享链接（网页地址），不是 CalDAV 地址。'
        + '请改用日历的「私有链接」：Nextcloud 网页版「日历 → 设置 → 复制私有链接」。';
    }
    return '';
  }

  /**
   * 是否为"只可能返回 405/404 的网页地址"——用于在探测前直接拦截，省一次请求。
   */
  static isWebPage(url: string): boolean {
    const k: string = DavDiscovery.classify(url);
    return k === 'share_calendar' || k === 'share_file';
  }

  /**
   * DAV 根 / 站点根 → 需要补全。用于判断是否值得走候选路径。
   * `/remote.php/dav` 或仅 origin 时，多半缺"日历家目录"这一层。
   */
  static looksIncomplete(url: string): boolean {
    const path: string = DavDiscovery.tidy(url).replace(/^https?:\/\/[^/]+/i, '').replace(/\/$/, '');
    if (path === '' || path === '/') {
      return true;                                  // 只填了域名
    }
    if (/\/remote\.php\/dav$/i.test(path)) {
      return true;                                  // DAV 根
    }
    if (/\/remote\.php\/dav\/(calendars|addressbooks)$/i.test(path)) {
      return true;                                  // 少了用户名一层
    }
    return false;
  }

  // ───────────────────────── 探测原语 ─────────────────────────

  /**
   * PROPFIND Depth:0 探测端点：只关心"能不能列、是不是 DAV"。
   * 不抛错：网络异常/状态码异常都返回可判定的结果。
   */
  static async probe(url: string, auth: string): Promise<number> {
    const body: string =
      '<?xml version="1.0" encoding="utf-8"?>' +
      '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>';
    const httpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await httpRequest.request(url, {
        method: 'PROPFIND' as http.RequestMethod,
        header: {
          'Authorization': auth,
          'Content-Type': 'application/xml; charset=utf-8',
          'Depth': '0',
          'User-Agent': 'SyncCalendar/1.0'
        },
        extraData: body,
        connectTimeout: 8000,
        readTimeout: 12000
      });
      LogUtil.write(`HTTP PROPFIND(发现) ${url} → ${resp.responseCode}`);
      return resp.responseCode;
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`PROPFIND(发现) ${url} 异常: ${e.code} - ${e.message}`);
      return 0; // 0 = 网络层失败
    } finally {
      httpRequest.destroy();
    }
  }

  /**
   * ⭐ OPTIONS 探测服务器的 DAV 能力：
   *  - 返回 `DAV:` 响应头 → 标准 WebDAV
   *  - 返回 `Allow` 里含 PROPFIND/REPORT → 支持 CalDAV 所需方法
   * 用于区分"这不是 DAV 端点"（如网页路由）与"服务端把方法挡了"。
   */
  static async optionsCapability(url: string, auth: string): Promise<DavCapability> {
    const cap = new DavCapability();
    const httpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await httpRequest.request(url, {
        method: http.RequestMethod.OPTIONS,
        header: {
          'Authorization': auth,
          'User-Agent': 'SyncCalendar/1.0'
        },
        connectTimeout: 8000,
        readTimeout: 12000
      });
      cap.status = resp.responseCode;
      const headers = resp.header as Record<string, string>;
      if (headers !== undefined && headers !== null) {
        // 头名大小写不统一，逐个大小写变体试
        const dav = headers['DAV'] ?? headers['Dav'] ?? headers['dav'] ?? '';
        const allow = headers['Allow'] ?? headers['allow'] ?? '';
        cap.davHeader = typeof dav === 'string' ? dav : '';
        cap.allow = typeof allow === 'string' ? allow : '';
        cap.isDav = cap.davHeader !== '' || /PROPFIND/i.test(cap.allow);
        cap.supportsPropfind = /PROPFIND/i.test(cap.allow) || cap.isDav;
        cap.supportsReport = /REPORT/i.test(cap.allow);
        // Allow 明确列出但两者都没有 → 大概率不是 DAV
        if (cap.allow !== '' && !cap.supportsPropfind) {
          cap.isDav = false;
        }
      }
      LogUtil.write(`OPTIONS ${url} → ${resp.responseCode}，DAV=${cap.davHeader || '(无)'}，Allow=${cap.allow || '(无)'}`);
      return cap;
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`OPTIONS ${url} 异常: ${e.code} - ${e.message}`);
      return cap;
    } finally {
      httpRequest.destroy();
    }
  }

  // ───────────────────────── 候选路径生成 ─────────────────────────

  /**
   * 生成候选「日历家目录 / 集合列表」端点。
   * @param base   用户填入并规范化后的地址
   * @param username 用户名（用于 Nextcloud 的 calendars/<用户名>/ 等模式）
   */
  static candidates(base: string, username: string): string[] {
    const origin: string = DavDiscovery.originOf(base);
    const out: string[] = [];
    if (origin === '') {
      return out;
    }
    const path: string = DavDiscovery.tidy(base).substring(origin.length);
    // 站点可能部署在子目录（如 /nextcloud）——保留用户填的前缀，只补 DAV 相关部分
    // 例：填 https://h/nextcloud → 前缀 /nextcloud
    let prefix: string = '';
    const idx: number = path.toLowerCase().indexOf('/remote.php');
    if (idx >= 0) {
      prefix = path.substring(0, idx);
    } else if (path !== '' && path !== '/') {
      prefix = path.replace(/\/$/, '');
    }
    const u: string = encodeURIComponent(username);
    const push = (p: string): void => {
      const full: string = origin + p;
      if (out.indexOf(full) < 0 && DavDiscovery.tidy(full) !== DavDiscovery.tidy(base)) {
        out.push(full);
      }
    };
    // Nextcloud / ownCloud
    push(`${prefix}/remote.php/dav/calendars/${u}/`);
    push(`${prefix}/remote.php/dav`);
    // Radicale（通常直接就是 /<用户名>/）
    push(`${prefix}/${u}/`);
    // Baïkal
    push(`${prefix}/dav.php/calendars/${u}/`);
    // 通用：直接在根下找
    push(`${prefix}/`);
    return out;
  }

  /**
   * ⭐ 主入口：在给定端点集合上依次探测，返回第一个"能列出日历"的端点。
   * 判据＝PROPFIND 得 207/200。真正的"日历集合筛选"仍由 DavClient.listCalendars 完成
   * （本方法只负责找到"哪个地址对"，避免与既有解析逻辑重复）。
   *
   * @param rawUrl   用户填入的原始地址（未规范化也可）
   * @param username 用户名
   * @param auth     Authorization 头
   * @param verify   可选的校验函数：传入端点，返回是否真的能列出日历（由调用方注入 listCalendars）
   */
  static async resolve(rawUrl: string, username: string, auth: string,
    verify?: (url: string) => Promise<boolean>): Promise<DiscoverResult> {
    const res = new DiscoverResult();
    const base: string = DavDiscovery.tidy(rawUrl);

    // ① 网页分享链接：直接拦下，不浪费请求
    const kind: string = DavDiscovery.classify(base);
    if (kind === 'share_calendar' || kind === 'share_file') {
      res.ok = false;
      res.hint = DavDiscovery.shareHint(kind);
      LogUtil.write(`发现：识别为网页分享链接，已拦截（${kind}）`);
      return res;
    }

    const check = async (url: string, via: string): Promise<boolean> => {
      const code: number = await DavDiscovery.probe(url, auth);
      if (code !== 207 && code !== 200) {
        return false;
      }
      if (verify !== undefined) {
        const good: boolean = await verify(url);
        if (!good) {
          return false;
        }
      }
      res.ok = true;
      res.url = url;
      res.via = via;
      res.readOnly = (kind === 'public_caldav');
      LogUtil.write(`发现成功（${via}）：${url}`);
      return true;
    };

    // ① 用户填的地址优先（保持既有行为）
    if (await check(base, 'direct')) {
      return res;
    }

    // ①b ⭐ 公开日历（只读订阅）：Nextcloud 的 public-calendars 链接本身即端点。
    //     此类端点通常无需认证，且只能读——后续由 SyncEngine 的写权限探测自动标记为只读。
    if (kind === 'public_caldav') {
      // 若用户填的是 public-calendars 根（少了 token），无法继续推断，直接给提示
      res.ok = false;
      res.hint = '这是「公开日历」链接但似乎不完整。请使用完整的公开日历地址'
        + '（形如 https://你的域名/remote.php/dav/public-calendars/<令牌>/），'
        + '或改用日历的「私有链接」以获得可读可写体验。';
      return res;
    }

    // ② .well-known/caldav（RFC 6764）——标准自动发现
    const origin: string = DavDiscovery.originOf(base);
    if (origin !== '') {
      const wk: string = await DavDiscovery.resolveWellKnown(origin, auth);
      if (wk !== '') {
        if (await check(wk, 'well-known')) {
          return res;
        }
        // .well-known 给了地址但直接探测不通过 → 也纳入候选由 ③ 继续尝试其下级
        LogUtil.write(`.well-known 指向 ${wk}，但该地址未通过日历校验，继续尝试常见路径`);
      }
    }

    // ③ 常见候选路径
    const cands: string[] = DavDiscovery.candidates(base, username);
    for (const c of cands) {
      if (await check(c, 'candidate')) {
        return res;
      }
    }

    // 全部失败 → 给可操作提示（区分"不是 DAV 端点"与"能连但列不出日历"）
    res.ok = false;
    const cap: DavCapability = await DavDiscovery.optionsCapability(base, auth);
    if (cap.status === 405 || (!cap.isDav && cap.allow !== '' && !cap.supportsPropfind)) {
      res.hint = '该地址不是 CalDAV 端点（服务器不接受 WebDAV 方法，返回 405）。'
        + '常见原因是填了网页分享链接、或只填了站点的 DAV 根。'
        + 'Nextcloud 请填「日历 → 设置 → 复制私有链接」得到的地址，例如：'
        + '`https://你的域名/remote.php/dav/calendars/你的用户名/`';
    } else if (cap.status === 401) {
      res.hint = '服务器拒绝凭据（401），请检查用户名与密码。'
        + 'Nextcloud 若开启了二次验证，需要使用「应用密码」。';
    } else if (cap.status === 301 || cap.status === 302) {
      res.hint = '服务器发生了跳转，通常说明 `.well-known/caldav` 未正确配置'
        + '（常见于反向代理或子目录部署）。可请 NAS 管理员把 `.well-known/caldav` '
        + '指向 `/remote.php/dav`，或直接填写完整的「日历家目录」地址。';
    } else {
      res.hint = '已连接上服务器，但在该地址下未发现任何日历本。'
        + '请确认填的是「日历家目录」而不是 DAV 根，例如：'
        + '`https://你的域名/remote.php/dav/calendars/你的用户名/`';
    }
    return res;
  }

  /**
   * 解析 .well-known/caldav：
   *  - 直接返回 207/200 → 该 URL 本身即端点
   *  - 返回 301/302/307/308 → 读 Location 头作为端点
   *  - 返回 401 时也读 Location（Nextcloud 常在认证后跳转）
   */
  static async resolveWellKnown(origin: string, auth: string): Promise<string> {
    const url: string = `${origin}/.well-known/caldav`;
    const httpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await httpRequest.request(url, {
        method: 'PROPFIND' as http.RequestMethod,
        header: {
          'Authorization': auth,
          'Content-Type': 'application/xml; charset=utf-8',
          'Depth': '0',
          'User-Agent': 'SyncCalendar/1.0'
        },
        extraData: '<?xml version="1.0" encoding="utf-8"?>' +
          '<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
        connectTimeout: 8000,
        readTimeout: 12000
      });
      LogUtil.write(`HTTP PROPFIND(.well-known) ${url} → ${resp.responseCode}`);
      if (resp.responseCode === 207 || resp.responseCode === 200) {
        return url;
      }
      if (resp.responseCode === 301 || resp.responseCode === 302
        || resp.responseCode === 307 || resp.responseCode === 308 || resp.responseCode === 401) {
        const headers = resp.header as Record<string, string>;
        if (headers !== undefined && headers !== null) {
          const loc = headers['Location'] ?? headers['location'] ?? '';
          if (typeof loc === 'string' && loc !== '') {
            const full: string = loc.startsWith('http') ? loc : origin + (loc.startsWith('/') ? '' : '/') + loc;
            LogUtil.write(`.well-known 跳转到：${full}`);
            return DavDiscovery.tidy(full);
          }
        }
      }
      return '';
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`.well-known 探测异常: ${e.code} - ${e.message}`);
      return '';
    } finally {
      httpRequest.destroy();
    }
  }

  /** 状态码是否表示"该地址不是 DAV 端点" */
  static isNotDav(code: number): boolean {
    return NOT_DAV_CODES.indexOf(code) >= 0;
  }

  // ───────────────────────── 给用户的"人话提示"（两个页面共用） ─────────────────────────

  /**
   * ⭐ 把 HTTP 状态码翻译成"人话 + 可操作指引"。
   * 用户看到"服务器返回 405"无从下手，这里直接告诉他下一步做什么。
   */
  static statusHint(code: number): string {
    if (code === 405) {
      return '该地址不是 CalDAV 端点（服务器不接受 WebDAV 方法，返回 405）。\n\n'
        + '常见原因：填了「分享链接」（网页地址），或只填到 DAV 根。\n'
        + '请填「日历家目录」，例如：\n'
        + 'https://你的域名/remote.php/dav/calendars/你的用户名/\n\n'
        + 'Nextcloud 可在网页版「日历 → 左下角设置 → 目标日历 → 复制私有链接」拿到这个地址。';
    }
    if (code === 401) {
      return '服务器拒绝凭据（401）：请检查用户名与密码。\n'
        + '若服务器开启了二次验证（2FA），需要使用「应用密码」而不是登录密码。';
    }
    if (code === 403) {
      return '服务器拒绝访问（403）：账号可能无权限，或 IP 被限制。请检查账号权限与服务器访问限制。';
    }
    if (code === 404) {
      return '地址不存在（404）：请检查路径是否写错。\n'
        + '正确形式通常为 https://你的域名/remote.php/dav/calendars/你的用户名/';
    }
    if (code === 301 || code === 302 || code === 307 || code === 308) {
      return '服务器发生跳转：通常说明 `.well-known/caldav` 未正确配置（常见于反向代理或子目录部署）。\n'
        + '请直接填写完整的「日历家目录」地址，或请 NAS 管理员配置 `.well-known/caldav`。';
    }
    if (code === 0) {
      return '无法连接服务器：请确认地址、端口与网络（内网地址需在同一局域网）。';
    }
    return `获取日历列表失败，服务器返回：${code}`;
  }

  /** ⭐ 能连上但"未发现日历本"时的提示：区分"地址差一层"与"确实是空的" */
  static emptyHint(url: string, username: string): string {
    if (DavDiscovery.looksIncomplete(url)) {
      const cands: string[] = DavDiscovery.candidates(url, username);
      const example: string = cands.length > 0 ? cands[0] : '';
      return '该地址下没有日历本 —— 多半是地址「少了一层」。\n\n'
        + '你填的是服务器根路径，但 CalDAV 需要填到「日历家目录」。请试试：\n'
        + (example !== '' ? example + '\n\n' : '\n')
        + '（Nextcloud 可在网页版「日历 → 设置 → 复制私有链接」直接拿到）';
    }
    return '该地址下未发现日历本。请确认：\n'
      + '1) 服务器上确实已创建日历；\n'
      + '2) 填的是「日历家目录」（形如 .../remote.php/dav/calendars/用户名/）而不是 DAV 根。';
  }
}

/** OPTIONS 探测结果 */
export class DavCapability {
  status: number = 0;
  davHeader: string = '';        // `DAV:` 响应头（含 "1", "2", "calendar-access" 等）
  allow: string = '';            // `Allow` 头
  isDav: boolean = false;
  supportsPropfind: boolean = false;
  supportsReport: boolean = false;
}