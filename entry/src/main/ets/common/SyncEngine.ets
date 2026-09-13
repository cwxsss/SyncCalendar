// entry/src/main/ets/common/SyncEngine.ets
// 双向同步引擎：先推本地修改（PUT/DELETE），再拉远端变更（REPORT + etag 增量）
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DavAccount } from './AccountStore';
import { EventDb, LocalEvent, RemoteEvent } from './EventDb';
import { IcsUtil } from './IcsUtil';
import { DavClient, DavColorEntry } from './DavClient';
import { LogUtil } from './LogUtil';

export class SyncEngine {
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
    const t0: number = Date.now();
    LogUtil.write(`========== 同步账号「${acc.name}」开始：服务器 ${acc.serverUrl}，共 ${acc.calendarHrefs.length} 个日历本 ==========`);
    try {
      const r: number = await SyncEngine.withTimeout<number>(
        SyncEngine.syncAccountInner(context, acc), 120000);
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
    // 2) 拉取远端变更（全量 REPORT，etag 增量落库）
    let changed: number = 0;
    for (let i = 0; i < acc.calendarHrefs.length; i++) {
      const href: string = acc.calendarHrefs[i];
      const calKey: string = `${acc.id}_${i}`;
      const calName: string = i < acc.calendarNames.length ? acc.calendarNames[i] : `日历本${i}`;
      LogUtil.write(`日历本[${i}]「${calName}」开始同步：${href}`);
      const t1: number = Date.now();
      const items = await DavClient.reportCalendar(href, auth);
      LogUtil.write(`日历本[${i}]「${calName}」REPORT 返回 ${items.length} 个资源`);
      const remote: RemoteEvent[] = [];
      let parseFail: number = 0;
      let failSample: string = '';
      for (const it of items) {
        const parsed: RemoteEvent[] = IcsUtil.parse(it.ics);
        if (parsed.length === 0) {
          parseFail++;
          if (failSample === '') {
            failSample = it.ics.replace(/\r?\n/g, ' ⏎ ').substring(0, 600);
          }
          continue;
        }
        // 一个资源可能包含主事件 + 单次覆盖实例（RECURRENCE-ID），全部入库
        for (const r of parsed) {
          if (r.uid === 'syncprobe') {
            continue; // 写权限探测资源（万一删除失败），不入库展示
          }
          if (r.uid === '') {
            r.uid = SyncEngine.uidFromHref(it.href);
          }
          r.etag = it.etag;
          remote.push(r);
        }
      }
      if (parseFail > 0) {
        LogUtil.write(`日历本[${i}]「${calName}」有 ${parseFail} 个资源解析出 0 条日程，首个样本: ${failSample}`);
      }
      LogUtil.write(`日历本[${i}]「${calName}」解析出 ${remote.length} 条日程，开始落库`);
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