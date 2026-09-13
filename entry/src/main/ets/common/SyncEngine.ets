// entry/src/main/ets/common/SyncEngine.ets
// 双向同步引擎：先推本地修改（PUT/DELETE），再拉远端变更（REPORT + etag 增量）
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DavAccount } from './AccountStore';
import { EventDb, LocalEvent, RemoteEvent } from './EventDb';
import { IcsUtil } from './IcsUtil';
import { DavClient, DavColorEntry, RemoteItem } from './DavClient';
import { LogUtil } from './LogUtil';
import { AppSettings } from './AppSettings';

export class SyncEngine {
  /** 正在同步中的账号 id → 开始时间：防止超时后的"僵尸同步"与新一轮同步并发写库 */
  private static activeSyncs: Map<string, number> = new Map();
  /** 互斥锁最长持有时间：超过视为异常残留（如进程挂起后网络停摆），允许抢占 */
  private static readonly LOCK_STALE_MS: number = 15 * 60 * 1000;

  /**
   * 给异步操作加超时保护，防止网络挂起导致界面一直转圈
   */
  static withTimeout<T>(task: Promise<T>, ms: number): Promise<T> {
    return Promise.race<T>([
      task,
      new Promise<T>((_resolve: (value: T) => void, reject: (reason?: Error) => void) => {
        setTimeout(() => reject(new Error(`同步超时(${Math.round(ms / 1000)}秒)`)), ms);
      })
    ]);
  }

  /**
   * 同步一个 CalDAV 账号（先推该账号的本地修改，再拉远端变更），
   * 返回远端事件总数（拉取侧）。带 120 秒超时保护。
   */
  static async syncAccount(context: common.Context, acc: DavAccount): Promise<number> {
    // 同一账号互斥：超时被掐断后内层任务仍在后台运行，期间不允许再次同步该账号。
    // 锁超过 LOCK_STALE_MS 未释放（如熄屏挂起导致任务冻结）则视为残留，允许抢占
    const heldSince: number | undefined = SyncEngine.activeSyncs.get(acc.id);
    if (heldSince !== undefined) {
      if (Date.now() - heldSince < SyncEngine.LOCK_STALE_MS) {
        throw new Error('该账号正在同步中，请稍后再试');
      }
      LogUtil.write(`同步互斥锁超时残留（${acc.name}），强制释放并重新同步`);
    }
    SyncEngine.activeSyncs.set(acc.id, Date.now());
    const t0: number = Date.now();
    LogUtil.write(`========== 同步账号「${acc.name}」开始：服务器 ${acc.serverUrl}，共 ${acc.calendarHrefs.length} 个日历本 ==========`);
    try {
      // 全量重拉（升级后首次）要逐个 GET 所有资源，放宽超时到 10 分钟；常规 5 分钟
      const fullRefetch: boolean = await AppSettings.isFullRefetchPending(context);
      const timeoutMs: number = fullRefetch ? 600000 : 300000;
      // 内层任务真正结束（无论成败）才释放互斥锁；超时后它仍会在后台跑完
      const inner: Promise<number> = SyncEngine.syncAccountInner(context, acc);
      inner.catch((): void => {}).finally((): void => {
        SyncEngine.activeSyncs.delete(acc.id);
      });
      const r: number = await SyncEngine.withTimeout<number>(inner, timeoutMs);
      LogUtil.write(`同步账号「${acc.name}」完成：拉取 ${r} 条日程，耗时 ${Math.round((Date.now() - t0) / 1000)} 秒`);
      return r;
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`同步账号「${acc.name}」失败：${e.message}（耗时 ${Math.round((Date.now() - t0) / 1000)} 秒）`);
      throw new Error(e.message !== '' ? e.message : `错误码 ${e.code}`);
    }
  }

  private static async syncAccountInner(context: common.Context, acc: DavAccount): Promise<number> {
    const auth: string = DavClient.authHeader(acc.username, acc.password);
    // 0) 刷新服务器端日历本颜色（每次同步都校正）
    await SyncEngine.refreshCalendarColors(acc, auth);
    // 1) 推送该账号日历本下的本地修改
    await SyncEngine.pushDirtyForAccount(context, acc, auth);
    // 2) 拉取远端变更：REPORT 仅取 etag；新增/变化的资源用 GET 补拉完整 ICS。
    //    原因：群晖等服务器的 REPORT calendar-data 会剥离 VALARM（提醒丢失），
    //    而 GET 返回完整 ICS；etag 未变的资源直接复用本地完整数据，几乎零开销。
    //    首次升级后执行一次全量重拉，修复旧模式落库的残缺数据（如 reminder=0）。
    const fullRefetch: boolean = await AppSettings.isFullRefetchPending(context);
    if (fullRefetch) {
      LogUtil.write('一次性全量重拉：忽略 etag 复用，全部资源 GET 完整 ICS');
    }
    let changed: number = 0;
    for (let i = 0; i < acc.calendarHrefs.length; i++) {
      const href: string = acc.calendarHrefs[i];
      const calKey: string = `${acc.id}_${i}`;
      const calName: string = i < acc.calendarNames.length ? acc.calendarNames[i] : `日历本${i}`;
      LogUtil.write(`日历本[${i}]「${calName}」开始同步：${href}`);
      const t1: number = Date.now();
      const items: RemoteItem[] = await DavClient.reportEtags(href, auth);
      LogUtil.write(`日历本[${i}]「${calName}」REPORT 返回 ${items.length} 个资源`);
      // 现有行按 uid 分组（同一资源的覆盖实例共享 uid 与 etag）
      const existingRows: LocalEvent[] = await EventDb.queryByCalKey(context, calKey, 'event');
      const byUid: Map<string, LocalEvent[]> = new Map();
      for (const row of existingRows) {
        const arr: LocalEvent[] | undefined = byUid.get(row.uid);
        if (arr === undefined) {
          byUid.set(row.uid, [row]);
        } else {
          arr.push(row);
        }
      }
      const originMatch = /https?:\/\/[^/]+/i.exec(href);
      const origin: string = originMatch !== null ? originMatch[0] : '';
      const remote: RemoteEvent[] = [];
      let fetched: number = 0;
      let parseFail: number = 0;
      const needFetch: RemoteItem[] = [];
      for (const it of items) {
        const resUid: string = SyncEngine.resUidFromHref(it.href);
        const group: LocalEvent[] | undefined = byUid.get(resUid);
        if (!fullRefetch && group !== undefined && group.length > 0 && !group[0].dirty
          && group[0].etag === it.etag) {
          // etag 未变：直接用本地行还原远端数据（含 reminder 等完整字段）
          for (const row of group) {
            remote.push(SyncEngine.rowToRemote(row, it.etag));
          }
          continue;
        }
        needFetch.push(it);
      }
      // 并发 GET 补拉（每批 5 个），避免全量重拉时串行请求超时
      const batchSize: number = 5;
      for (let b: number = 0; b < needFetch.length; b += batchSize) {
        const batch: RemoteItem[] = needFetch.slice(b, b + batchSize);
        const results: RemoteEvent[][] = await Promise.all(batch.map(async (it: RemoteItem): Promise<RemoteEvent[]> => {
          const url: string = it.href.startsWith('http') ? it.href : origin + it.href;
          try {
            const raw: string = await DavClient.getRaw(url, auth);
            if (!raw.startsWith('BEGIN:VCALENDAR')) {
              return [];
            }
            const resUid: string = SyncEngine.resUidFromHref(it.href);
            const parsed: RemoteEvent[] = IcsUtil.parse(raw);
            const out: RemoteEvent[] = [];
            for (const r of parsed) {
              if (r.uid === 'syncprobe') {
                continue; // 写权限探测资源（万一删除失败），不入库展示
              }
              if (r.uid === '') {
                r.uid = resUid;
              }
              r.etag = it.etag;
              out.push(r);
            }
            return out;
          } catch (err) {
            return [];
          }
        }));
        for (const arr of results) {
          if (arr.length === 0) {
            parseFail++;
          } else {
            fetched++;
            for (const r of arr) {
              remote.push(r);
            }
          }
        }
      }
      if (parseFail > 0) {
        LogUtil.write(`日历本[${i}]「${calName}」有 ${parseFail} 个资源拉取/解析失败`);
      }
      LogUtil.write(`日历本[${i}]「${calName}」补拉变更资源 ${fetched} 个，共 ${remote.length} 条日程，开始落库`);
      const stat: string = await EventDb.applyRemote(context, calKey, href, remote, false);
      LogUtil.write(`日历本[${i}]「${calName}」日程落库完成：${stat}，耗时 ${Math.round((Date.now() - t1) / 1000)} 秒`);
      changed += remote.length;
      // 3) 拉取该日历本下的待办（VTODO，只读展示，拉取失败不影响日程同步）
      try {
        const todoItems = await DavClient.reportTodos(href, auth);
        const remoteTodos: RemoteEvent[] = [];
        for (const it of todoItems) {
          const parsedTodos: RemoteEvent[] = IcsUtil.parseTodos(it.ics);
          for (const t of parsedTodos) {
            if (t.uid === '') {
              t.uid = SyncEngine.uidFromHref(it.href);
            }
            t.etag = it.etag;
            remoteTodos.push(t);
          }
        }
        const tstat: string = await EventDb.applyRemote(context, calKey, href, remoteTodos, true);
        LogUtil.write(`日历本[${i}]「${calName}」待办：REPORT ${todoItems.length} 个资源，解析 ${remoteTodos.length} 条，${tstat}`);
      } catch (err) {
        const te = err as BusinessError;
        LogUtil.write(`日历本[${i}]「${calName}」拉取待办失败(忽略)：${te.message}`);
      }
    }
    return changed;
  }

  /**
   * 刷新服务器端日历本颜色：PROPFIND getcolor → 按集合路径匹配更新 acc.calendarColors
   * 失败静默（颜色不影响数据正确性）
   */
  static async refreshCalendarColors(acc: DavAccount, auth: string): Promise<void> {
    let entries: DavColorEntry[] = [];
    try {
      entries = await DavClient.propfindColors(acc.serverUrl, auth);
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`PROPFIND 颜色/权限失败(继续探测写权限): ${e.message}`);
    }
    for (let i = 0; i < acc.calendarHrefs.length; i++) {
      const target: string = acc.calendarHrefs[i];
      const originMatch = /https?:\/\/[^/]+/i.exec(target);
      let path: string = originMatch !== null ? target.substring(originMatch[0].length) : target;
      if (path === '') {
        path = '/';
      }
      const norm = (s: string): string => s.endsWith('/') ? s : s + '/';
      const found = entries.find((e: DavColorEntry): boolean =>
        norm(e.href) === norm(path));
      if (found !== undefined && found.color !== '') {
        while (acc.calendarColors.length <= i) {
          acc.calendarColors.push('');
        }
        acc.calendarColors[i] = found.color;
      }
      // 回写各日历本写权限（'1'=可写 '0'=只读）
      while (acc.calendarWritable.length <= i) {
        acc.calendarWritable.push('1');
      }
      const calName: string = i < acc.calendarNames.length ? acc.calendarNames[i] : `日历本${i}`;
      if (found !== undefined && found.privilegeKnown) {
        // 服务器声明了权限：直接采用
        acc.calendarWritable[i] = found.writable ? '1' : '0';
        LogUtil.write(`日历本[${i}]「${calName}」写权限(privilege)：${found.writable ? '可写' : '只读'}`);
      } else {
        // 服务器未声明权限（如部分 Synology 配置）或 PROPFIND 未匹配到该本：真实写探测
        const w: boolean = await DavClient.probeWritable(target, auth);
        acc.calendarWritable[i] = w ? '1' : '0';
        LogUtil.write(`日历本[${i}]「${calName}」写权限(探测)：${w ? '可写' : '只读'}`);
      }
    }
  }

  /** 从资源 URL 提取 UID（解析失败时的兜底） */
  private static uidFromHref(href: string): string {
    const segs: string[] = href.split('/').filter((s: string): boolean => s !== '');
    if (segs.length === 0) {
      return String(Date.now());
    }
    const last: string = segs[segs.length - 1];
    return last.endsWith('.ics') ? last.substring(0, last.length - 4) : last;
  }

  /** 从资源 URL 提取 UID（URL 解码后，用于与 DB 中 parse 出的真实 uid 匹配） */
  private static resUidFromHref(href: string): string {
    const segs: string[] = href.split('/').filter((s: string): boolean => s !== '');
    if (segs.length === 0) {
      return String(Date.now());
    }
    let last: string = segs[segs.length - 1];
    if (last.endsWith('.ics')) {
      last = last.substring(0, last.length - 4);
    }
    try {
      last = decodeURIComponent(last);
    } catch (err) {
      // 解码失败保持原样
    }
    return last;
  }

  /** 本地行 → 远端事件（etag 未变的资源复用本地完整数据，含 reminder） */
  private static rowToRemote(e: LocalEvent, etag: string): RemoteEvent {
    const r = new RemoteEvent();
    r.uid = e.uid;
    r.etag = etag;
    r.title = e.title;
    r.description = e.description;
    r.location = e.location;
    r.startTime = e.startTime;
    r.endTime = e.endTime;
    r.isAllDay = e.isAllDay;
    r.recurring = e.recurring;
    r.completed = e.completed;
    r.rrule = e.rrule;
    r.exdate = e.exdate;
    r.reminder = e.reminder;
    return r;
  }

  /**
   * 推送指定账号日历本下的待同步事件（新建/修改 → PUT；删除 → DELETE）
   */
  static async pushDirtyForAccount(context: common.Context, acc: DavAccount, auth: string): Promise<void> {
    const dirty: LocalEvent[] = await EventDb.getDirty(context);
    const mine: LocalEvent[] = dirty.filter((e: LocalEvent): boolean => acc.calendarHrefs.includes(e.href));
    LogUtil.write(`推送本地修改：全部待推送 ${dirty.length} 条，属于账号「${acc.name}」的 ${mine.length} 条`);
    for (const e of mine) {
      // 只读日历本：推送必然 403，跳过并保留 dirty（权限恢复后可再推）
      const bookIdx: number = acc.calendarHrefs.indexOf(e.href);
      if (bookIdx >= 0 && acc.calendarWritable.length > bookIdx
        && acc.calendarWritable[bookIdx] === '0') {
        LogUtil.write(`推送跳过只读日历本事件「${e.title}」(uid=${e.uid})`);
        continue;
      }
      if (e.kind === 'todo') {
        // 待办只读：本地不会有 dirty 待办，兜底清除
        await EventDb.clearDirty(context, e.id, e.etag);
        continue;
      }
      if (e.recurring && e.rrule === '') {
        // 重复日程的"单次覆盖实例"（RECURRENCE-ID）推送会破坏服务器整个序列，暂不支持
        await EventDb.clearDirty(context, e.id, e.etag);
        LogUtil.write(`推送跳过重复日程实例「${e.title}」(uid=${e.uid})`);
        continue;
      }
      if (e.recurring) {
        // 重复主事件（含 RRULE，含本机新建的重复日程）：整条 PUT 覆盖推送
        LogUtil.write(`推送重复主事件「${e.title}」(uid=${e.uid})`);
      }
      const url: string = e.href.endsWith('/') ? e.href + e.remotePath : `${e.href}/${e.remotePath}`;
      if (e.deleted) {
        await DavClient.deleteRemote(url, auth);
        await EventDb.purge(context, e.id);
        LogUtil.write(`推送删除「${e.title}」→ ${url}`);
      } else {
        const ics: string = IcsUtil.build(e);
        const etag: string = await DavClient.putEvent(url, auth, ics);
        await EventDb.clearDirty(context, e.id, etag);
        LogUtil.write(`推送保存「${e.title}」→ ${url}（${ics.length} 字节）`);
      }
    }
  }

  /**
   * 清理本机虚拟日历（calKey=local）的待推送状态：
   * 本机事件不参与 DAV 同步，直接落地
   */
  static async settleLocalEvents(context: common.Context): Promise<void> {
    const dirty: LocalEvent[] = await EventDb.getDirty(context);
    for (const e of dirty) {
      if (e.href !== '') {
        continue;
      }
      if (e.deleted) {
        await EventDb.purge(context, e.id);
      } else {
        await EventDb.clearDirty(context, e.id, '');
      }
    }
  }

  /**
   * 清理孤儿日程行：calKey 不属于任何现有账号（accId_ 前缀）也不是本机日历（local）的历史残留。
   * 典型如账号重建/日历重选后遗留的 `_13`、`acc1789274273124_0_13` 等，
   * 这些行会参与重复日程的 override 排除计算，导致重复日程第一次发生不显示。
   * 建议在所有账号同步完成后调用。
   */
  static async pruneOrphanRows(context: common.Context, accounts: DavAccount[]): Promise<void> {
    try {
      // 防御：账号列表为空时（如同步中途读取异常），绝不能把所有 CalDAV 日程当孤儿清理
      if (accounts.length === 0) {
        LogUtil.write('清理孤儿日程行跳过：账号列表为空（防御保护）');
        return;
      }
      const accIds: string[] = accounts.map((a: DavAccount): string => a.id);
      const removed: number = await EventDb.pruneOrphanCalKeys(context, accIds);
      if (removed > 0) {
        LogUtil.write(`清理孤儿日程行：${removed} 条（calKey 不属于任何现有账号）`);
      }
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`清理孤儿日程行失败(忽略)：${e.message}`);
    }
  }
}