import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DavAccount } from './AccountStore';
import { AccountStore } from './AccountStore';
import { LocalEvent } from './EventDb';
import { EventDb } from './EventDb';
import { DavClient, DavHttpError } from './DavClient';
import { IcsUtil } from './IcsUtil';
import { LogUtil } from './LogUtil';

/**
 * 待办（VTODO）操作。
 *
 * 现状：待办**只读展示**已实现（拉取/解析/入库/列表），本类补上唯一的写操作
 * ——「勾选完成 / 取消完成」。
 *
 * ⚠️ 为什么不做"从本地字段重建 VTODO 再 PUT"：
 *   VTODO 上有 SUMMARY / DESCRIPTION / DUE / PRIORITY / CATEGORIES / X-* 等字段，
 *   本地库只存了其中几个。重建后 PUT 等于把没存的字段**全部抹掉**。
 *   所以走"GET 原文 → 就地改 STATUS/COMPLETED/PERCENT-COMPLETE → PUT"。
 *
 * ⚠️ 为什么不能同步到手机系统待办：
 *   系统未开放待办 API（@ohos.calendarManager 只有日程/VEVENT，无 Todo 对象），
 *   第三方应用无法读写系统日历的「待办」页签。详见工单 #5。
 */
export class TodoService {
  /**
   * 设置待办完成状态并回写服务器。
   *
   * @param localId 本地 events 表行 id（DisplayEvent.id）
   * @param done    true=标记完成；false=取消完成
   * @returns 成功返回 true；失败返回 false（**本地状态不变**，避免界面与服务器不一致）
   */
  static async setCompleted(context: common.Context, localId: number, done: boolean): Promise<boolean> {
    const row: LocalEvent | null = await EventDb.queryById(context, localId);
    if (row === null) {
      LogUtil.write(`待办完成失败：本地行不存在 id=${localId}`);
      return false;
    }
    if (row.kind !== 'todo') {
      LogUtil.write(`待办完成失败：该行不是待办 id=${localId} kind=${row.kind}`);
      return false;
    }
    if (row.href === '' || row.remotePath === '') {
      LogUtil.write(`待办完成失败：缺少服务器路径（不可写）id=${localId}`);
      return false;
    }
    if (row.completed === done) {
      return true; // 状态没变化，直接算成功（幂等）
    }

    // 1) 找到该 href 所属账号，构造鉴权
    const accounts: DavAccount[] = await AccountStore.loadAll(context);
    let acc: DavAccount | null = null;
    for (const a of accounts) {
      if (a.calendarHrefs.includes(row.href)) {
        acc = a;
        break;
      }
    }
    if (acc === null) {
      LogUtil.write(`待办完成失败：找不到所属账号 href=${row.href}`);
      return false;
    }
    // 只读日历本：推送必然 403，提前拦下给出明确结果
    const idx: number = acc.calendarHrefs.indexOf(row.href);
    if (idx >= 0 && acc.calendarWritable.length > idx && acc.calendarWritable[idx] === '0') {
      LogUtil.write(`待办完成失败：该日历本只读 id=${localId}`);
      return false;
    }

    const auth: string = DavClient.authHeader(acc.username, acc.password);
    const url: string = row.href.endsWith('/') ? row.href + row.remotePath : `${row.href}/${row.remotePath}`;

    try {
      // 2) GET 原文（保住本地没存的字段）
      const original: string = await DavClient.getRawStrict(url, auth);
      if (!original.toUpperCase().includes('BEGIN:VTODO')) {
        LogUtil.write(`待办完成失败：服务器返回的内容不是 VTODO id=${localId}`);
        return false;
      }

      // 3) 只改状态相关字段
      const updated: string = IcsUtil.rewriteTodoCompletion(original, row.uid, done);

      // 4) PUT 回去，拿新 etag
      const newEtag: string = await DavClient.putEvent(url, auth, updated);

      // 5) 同步本地（成功后才改，保证两边一致）
      await EventDb.setTodoCompleted(context, localId, done, newEtag);
      LogUtil.write(`待办${done ? '完成' : '取消完成'}成功 id=${localId}（标题已脱敏）`);
      return true;
    } catch (err) {
      if (err instanceof DavHttpError) {
        const he = err as DavHttpError;
        LogUtil.write(`待办写回失败 HTTP ${he.status}：id=${localId}（本地状态未改）`);
      } else {
        const e = err as BusinessError;
        LogUtil.write(`待办写回失败：id=${localId} ${e.message ?? ''}（本地状态未改）`);
      }
      return false;
    }
  }
}