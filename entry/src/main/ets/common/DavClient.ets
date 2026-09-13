// entry/src/main/ets/common/DavClient.ets
// CalDAV HTTP 客户端：REPORT / PUT / DELETE
import { http } from '@kit.NetworkKit';
import { buffer } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { LogUtil } from './LogUtil';

/** REPORT 返回的单个远端资源 */
export class RemoteItem {
  href: string = '';   // 资源完整 URL
  etag: string = '';
  ics: string = '';    // VCALENDAR 文本
}

/** PROPFIND 返回的集合颜色 */
export class DavColorEntry {
  href: string = '';   // 集合路径（服务器返回的是路径，不带域名）
  color: string = '';  // 规范化后的 #RRGGBB，可能为空
}

export class DavClient {
  /**
   * PROPFIND 拉取某路径下所有集合的 calendar-color
   * 返回「集合路径 → 颜色」列表（路径为服务器返回的原始 href）
   */
  static async propfindColors(serverUrl: string, auth: string): Promise<DavColorEntry[]> {
    const requestBody: string = '<?xml version="1.0" encoding="utf-8"?>' +
      '<d:propfind xmlns:d="DAV:" xmlns:cs="http://calendarserver.org/ns/" ' +
      'xmlns:ical="http://apple.com/ns/ical/"><d:prop>' +
      '<d:resourcetype/><cs:getcolor/><ical:calendar-color/>' +
      '</d:prop></d:propfind>';
    const httpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await httpRequest.request(serverUrl, {
        method: 'PROPFIND' as http.RequestMethod,
        header: {
          'Authorization': auth,
          'Content-Type': 'application/xml; charset=utf-8',
          'Depth': '1',
          'User-Agent': 'SyncCalendar/1.0'
        },
        extraData: requestBody,
        connectTimeout: 10000,
        readTimeout: 20000
      });
      console.info(`PROPFIND(颜色) 响应码: ${resp.responseCode}`);
      LogUtil.write(`HTTP PROPFIND(颜色) ${serverUrl} → ${resp.responseCode}`);
      if (resp.responseCode !== 207 && resp.responseCode !== 200) {
        return [];
      }
      const xml: string = resp.result as string;
      const result: DavColorEntry[] = [];
      const blocks: string[] = xml.split(/<\/[\w-]*:?response>/i);
      for (const block of blocks) {
        if (!/<[\w-]*:?response[\s>]/i.test(block)) {
          continue;
        }
        const href: string = DavClient.extractTag(block, 'href');
        if (href === '') {
          continue;
        }
        const resourcetype: string = DavClient.extractTag(block, 'resourcetype');
        if (!/calendar/i.test(resourcetype)) {
          continue;
        }
        const entry = new DavColorEntry();
        entry.href = href;
        // 两个命名空间都试：cs:getcolor（CalendarServer）/ ical:calendar-color（Apple）
        let color: string = DavClient.normalizeHex(DavClient.extractTag(block, 'getcolor'));
        if (color === '') {
          color = DavClient.normalizeHex(DavClient.extractTag(block, 'calendar-color'));
        }
        entry.color = color;
        result.push(entry);
      }
      if (result.length > 0 && result.every((e: DavColorEntry): boolean => e.color === '')) {
        // 全部没拿到颜色时打印原始响应片段，便于诊断命名空间
        console.info(`PROPFIND(颜色) 未取到颜色，响应片段: ${xml.substring(0, 600)}`);
      }
      return result;
    } finally {
      httpRequest.destroy();
    }
  }

  /** 颜色规范化：#RRGGBBAA → #RRGGBB */
  static normalizeHex(raw: string): string {
    const v: string = raw.trim();
    if (/^#[0-9A-Fa-f]{8}$/.test(v)) {
      return '#' + v.substring(3, 9).toUpperCase();
    }
    if (/^#[0-9A-Fa-f]{6}$/.test(v)) {
      return v.toUpperCase();
    }
    return '';
  }

  /** Basic Auth 头 */
  static authHeader(username: string, password: string): string {
    return 'Basic ' + buffer.from(`${username}:${password}`).toString('base64');
  }

  /** REPORT calendar-query：全量拉取某日历本内所有 VEVENT（不加时间范围，保证数据完整） */
  static async reportCalendar(href: string, auth: string): Promise<RemoteItem[]> {
    return DavClient.reportComponents(href, auth, 'VEVENT', '');
  }

  /** REPORT calendar-query：拉取某日历本内所有 VTODO 待办（不限时间范围，量小） */
  static async reportTodos(href: string, auth: string): Promise<RemoteItem[]> {
    return DavClient.reportComponents(href, auth, 'VTODO', '');
  }

  /** 通用 REPORT：按组件类型过滤拉取 calendar-data + getetag */
  private static async reportComponents(href: string, auth: string,
    compName: string, timeRange: string): Promise<RemoteItem[]> {
    const body: string = '<?xml version="1.0" encoding="utf-8"?>' +
      '<c:calendar-query xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">' +
      '<d:prop><d:getetag/><c:calendar-data/></d:prop>' +
      '<c:filter><c:comp-filter name="VCALENDAR">' +
      `<c:comp-filter name="${compName}">` +
      timeRange +
      '</c:comp-filter></c:comp-filter></c:filter></c:calendar-query>';
    const httpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await httpRequest.request(href, {
        method: 'REPORT' as http.RequestMethod,
        header: {
          'Authorization': auth,
          'Content-Type': 'application/xml; charset=utf-8',
          'Depth': '1',
          'User-Agent': 'SyncCalendar/1.0'
        },
        extraData: body,
        connectTimeout: 10000,
        readTimeout: 60000
      });
      console.info(`REPORT(${compName}) ${href} 响应码: ${resp.responseCode}`);
      LogUtil.write(`HTTP REPORT(${compName}) ${href} → ${resp.responseCode}`);
      if (resp.responseCode === 401) {
        LogUtil.write(`HTTP REPORT(${compName}) 401 拒绝凭据`);
        throw new Error('服务器拒绝凭据(401)');
      }
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        LogUtil.write(`HTTP REPORT(${compName}) 异常状态码 ${resp.responseCode}`);
        throw new Error(`服务器返回状态码 ${resp.responseCode}`);
      }
      const xml: string = resp.result as string;
      LogUtil.write(`HTTP REPORT(${compName}) 响应体 ${xml.length} 字符`);
      const originMatch = /https?:\/\/[^/]+/i.exec(href);
      const origin: string = originMatch !== null ? originMatch[0] : '';
      const items: RemoteItem[] = [];
      const blocks: string[] = xml.split(/<\/[\w-]*:?response>/i);
      for (const block of blocks) {
        if (!/<[\w-]*:?response[\s>]/i.test(block)) {
          continue;
        }
        const resHref: string = DavClient.extractTag(block, 'href');
        if (resHref === '') {
          continue;
        }
        const etag: string = DavClient.extractTag(block, 'getetag').replace(/"/g, '');
        const start: number = block.indexOf('BEGIN:VCALENDAR');
        const end: number = block.indexOf('END:VCALENDAR');
        if (start < 0 || end < 0) {
          continue;
        }
        const item = new RemoteItem();
        item.href = resHref.startsWith('http') ? resHref : origin + resHref;
        item.etag = etag;
        item.ics = block.substring(start, end + 'END:VCALENDAR'.length);
        items.push(item);
      }
      return items;
    } finally {
      httpRequest.destroy();
    }
  }

  /** PUT 新建/更新远端事件，返回响应 ETag（可能为空） */
  static async putEvent(url: string, auth: string, ics: string): Promise<string> {
    const httpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await httpRequest.request(url, {
        method: http.RequestMethod.PUT,
        header: {
          'Authorization': auth,
          'Content-Type': 'text/calendar; charset=utf-8',
          'User-Agent': 'SyncCalendar/1.0'
        },
        extraData: ics,
        connectTimeout: 10000,
        readTimeout: 30000
      });
      console.info(`PUT ${url} 响应码: ${resp.responseCode}`);
      LogUtil.write(`HTTP PUT ${url} → ${resp.responseCode}`);
      if (resp.responseCode < 200 || resp.responseCode >= 300) {
        throw new Error(`推送失败，服务器返回 ${resp.responseCode}`);
      }
      const headers = resp.header as Record<string, string>;
      if (headers !== undefined && headers !== null) {
        const etag = headers['ETag'] ?? headers['etag'] ?? '';
        return typeof etag === 'string' ? etag.replace(/"/g, '') : '';
      }
      return '';
    } finally {
      httpRequest.destroy();
    }
  }

  /** DELETE 远端事件 */
  static async deleteRemote(url: string, auth: string): Promise<void> {
    const httpRequest = http.createHttp();
    try {
      const resp: http.HttpResponse = await httpRequest.request(url, {
        method: http.RequestMethod.DELETE,
        header: {
          'Authorization': auth,
          'User-Agent': 'SyncCalendar/1.0'
        },
        connectTimeout: 10000,
        readTimeout: 30000
      });
      console.info(`DELETE ${url} 响应码: ${resp.responseCode}`);
      LogUtil.write(`HTTP DELETE ${url} → ${resp.responseCode}`);
      // 404 视为已删除，成功
      if ((resp.responseCode < 200 || resp.responseCode >= 300) && resp.responseCode !== 404) {
        throw new Error(`删除失败，服务器返回 ${resp.responseCode}`);
      }
    } finally {
      httpRequest.destroy();
    }
  }

  /** 提取任意命名空间前缀标签的内容 */
  static extractTag(xml: string, tag: string): string {
    const pattern: string = '<([\\w-]+:)?' + tag + '(?:\\s[^>]*)?>([\\s\\S]*?)<\\/([\\w-]+:)?' + tag + '>';
    const regex: RegExp = new RegExp(pattern, 'i');
    const match = regex.exec(xml);
    return match !== null ? match[2].trim() : '';
  }
}