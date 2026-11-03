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
  /**
   * 更新待办内容（标题 / 备注 / 截止时间）。
   *
   * 同样走 GET 原文 → 改字段 → PUT：
   *   VTODO 上有本地库没保存的字段（PRIORITY / CATEGORIES / X-* 等），
   *   重建整份会把这些抹掉。
   *
   * 只改 SUMMARY / DESCRIPTION / DUE 三项，**不动完成状态**
   * （用户改的是内容，不该顺带把状态重置了）。
   *
   * @param dueMs 0 = 清除截止时间（删除 DUE 行）
   */
  static async updateTodo(context: common.Context, localId: number, title: string,
    desc: string, dueMs: number): Promise<boolean> {
    const row: LocalEvent | null = await EventDb.queryById(context, localId);
    if (row === null || row.kind !== 'todo') {
      LogUtil.write(`待办更新失败：行不存在或不是待办 id=${localId}`);
      return false;
    }
    if (row.href === '' || row.remotePath === '') {
      LogUtil.write(`待办更新失败：缺少服务器路径 id=${localId}`);
      return false;
    }
    const accResolved: DavAccount | null = await TodoService.findAccount(context, row.href);
    if (accResolved === null) {
      LogUtil.write(`待办更新失败：找不到所属账号`);
      return false;
    }
    const idx: number = accResolved.calendarHrefs.indexOf(row.href);
    if (idx >= 0 && accResolved.calendarWritable.length > idx
      && accResolved.calendarWritable[idx] === '0') {
      LogUtil.write(`待办更新失败：该日历本只读 id=${localId}`);
      return false;
    }
    const auth: string = DavClient.authHeader(accResolved.username, accResolved.password);
    const url: string = row.href.endsWith('/') ? row.href + row.remotePath
      : `${row.href}/${row.remotePath}`;
    try {
      const original: string = await DavClient.getRawStrict(url, auth);
      if (!original.toUpperCase().includes('BEGIN:VTODO')) {
        LogUtil.write(`待办更新失败：服务器内容不是 VTODO id=${localId}`);
        return false;
      }
      const updated: string = IcsUtil.rewriteTodoFields(original, row.uid, title, desc, dueMs);
      const newEtag: string = await DavClient.putEvent(url, auth, updated);
      await EventDb.updateTodoFields(context, localId, title, desc,
        dueMs > 0 ? dueMs : 0, newEtag);
      LogUtil.write(`待办更新成功 id=${localId}（标题已脱敏）`);
      return true;
    } catch (err) {
      if (err instanceof DavHttpError) {
        LogUtil.write(`待办更新失败 HTTP ${(err as DavHttpError).status} id=${localId}`);
      } else {
        LogUtil.write(`待办更新失败 id=${localId} ${(err as BusinessError).message ?? ''}`);
      }
      return false;
    }
  }

  /**
   * 新建待办：生成 VTODO → PUT 到服务器 → 落本地库。
   *
   * @param href   目标日历本的集合 URL
   * @param title  标题（调用方保证非空）
   * @param desc   备注（可为空串）
   * @param dueMs  截止时间毫秒（0 = 无截止）
   * @param dueIsDateOnly 截止时间是否只到日（true 写 DUE;VALUE=DATE）
   * @returns 成功返回新行 id（>0），失败返回 0
   */
  static async createTodo(context: common.Context, href: string, title: string,
    desc: string, dueMs: number, dueIsDateOnly: boolean): Promise<number> {
    const t: string = title.trim();
    if (t === '' || href === '') {
      LogUtil.write(`待办新建失败：标题或日历本为空`);
      return 0;
    }
    // 1) 找到该 href 所属账号
    const acc: DavAccount | null = await TodoService.findAccount(context, href);
    if (acc === null) {
      LogUtil.write(`待办新建失败：找不到所属账号 href=${href}`);
      return 0;
    }
    // 2) 只读日历本提前拦下（否则必然 403）
    const idx: number = acc.calendarHrefs.indexOf(href);
    if (idx >= 0 && acc.calendarWritable.length > idx && acc.calendarWritable[idx] === '0') {
      LogUtil.write(`待办新建失败：该日历本只读 href=${href}`);
      return 0;
    }

    // 3) 生成 uid 与资源文件名
    //    格式与事件侧一致：todo-<毫秒时间戳>-<随机6位>，足够避免撞车
    const stamp: number = Date.now();
    const rnd: string = Math.random().toString(36).substring(2, 8);
    const uid: string = `todo-${stamp}-${rnd}`;
    const fileName: string = `${uid}.ics`;
    const url: string = href.endsWith('/') ? href + fileName : `${href}/${fileName}`;
    const auth: string = DavClient.authHeader(acc.username, acc.password);

    try {
      // 4) 先推服务器：成功才落库，避免产生"本地有、服务器没有"的孤儿
      const ics: string = IcsUtil.buildTodo(uid, t, desc, dueMs, dueIsDateOnly);
      const etag: string = await DavClient.putEvent(url, auth, ics);

      // 5) 落本地库（insertLocal 会置 dirty=true，但 etag 已写回故不会被重复推送）
      const e: LocalEvent = new LocalEvent();
      e.uid = uid;
      e.calKey = `${acc.id}_${idx}`;
      e.href = href;
      e.remotePath = fileName;
      e.etag = etag;
      e.kind = 'todo';
      e.title = t;
      e.description = desc;
      e.startTime = dueMs > 0 ? dueMs : 0; // 待办的"开始"即截止（与 loadTodos 口径一致）
      e.endTime = dueMs > 0 ? dueMs : 0;
      e.isAllDay = dueIsDateOnly;
      e.completed = false;
      e.dirty = false;  // 已经推成功了，无需再推
      e.deleted = false;
      const newId: number = await EventDb.insertLocal(context, e);
      // insertLocal 强制置 dirty=true，这里立刻清掉（内容已在服务器上了）
      await EventDb.clearDirty(context, newId, etag);
      LogUtil.write(`待办新建成功 id=${newId}（标题已脱敏）→ ${fileName}`);
      return newId;
    } catch (err) {
      if (err instanceof DavHttpError) {
        LogUtil.write(`待办新建失败 HTTP ${(err as DavHttpError).status}（标题已脱敏）`);
      } else {
        LogUtil.write(`待办新建失败 ${(err as BusinessError).message ?? ''}`);
      }
      return 0;
    }
  }

  /** 删除待办（DELETE 服务器资源 + 本地软删） */
  static async deleteTodo(context: common.Context, localId: number): Promise<boolean> {
    const row: LocalEvent | null = await EventDb.queryById(context, localId);
    if (row === null || row.kind !== 'todo') {
      LogUtil.write(`待办删除失败：行不存在或不是待办 id=${localId}`);
      return false;
    }
    if (row.href === '' || row.remotePath === '') {
      LogUtil.write(`待办删除失败：缺少服务器路径 id=${localId}`);
      return false;
    }
    const accResolved: DavAccount | null = await TodoService.findAccount(context, row.href);
    if (accResolved === null) {
      LogUtil.write(`待办删除失败：找不到所属账号`);
      return false;
    }
    const idx: number = accResolved.calendarHrefs.indexOf(row.href);
    if (idx >= 0 && accResolved.calendarWritable.length > idx
      && accResolved.calendarWritable[idx] === '0') {
      LogUtil.write(`待办删除失败：该日历本只读 id=${localId}`);
      return false;
    }
    const auth: string = DavClient.authHeader(accResolved.username, accResolved.password);
    const url: string = row.href.endsWith('/') ? row.href + row.remotePath
      : `${row.href}/${row.remotePath}`;
    try {
      await DavClient.deleteRemote(url, auth);
      await EventDb.purge(context, localId);
      LogUtil.write(`待办删除成功 id=${localId}（标题已脱敏）`);
      return true;
    } catch (err) {
      if (err instanceof DavHttpError) {
        LogUtil.write(`待办删除失败 HTTP ${(err as DavHttpError).status} id=${localId}`);
      } else {
        LogUtil.write(`待办删除失败 id=${localId} ${(err as BusinessError).message ?? ''}`);
      }
      return false;
    }
  }

  /** 按 href 找所属账号（updateTodo/deleteTodo 共用） */
  private static async findAccount(context: common.Context, href: string): Promise<DavAccount | null> {
    const accounts: DavAccount[] = await AccountStore.loadAll(context);
    for (const a of accounts) {
      if (a.calendarHrefs.includes(href)) {
        return a;
      }
    }
    return null;
  }

  /**
   * 设置或取消待办的循环规则。
   *
   * @param rrule 规则原文（如 `FREQ=WEEKLY`）；空串 = 取消循环
   * @param dtstartMs 重复基准；<=0 时用当前 DUE 兜底
   * @returns 成功 true
   *
   * ⚠️ 写回时**同时**给 DTSTART 和 DUE：
   *    RFC 5545 里 VTODO 的 DTSTART 是 OPTIONAL，但没有它时
   *    不同客户端对 RRULE 基准的理解不一致（有的按 DUE 算），
   *    显式给 DTSTART 能消除歧义。
   */
  static async setRecurrence(context: common.Context, localId: number,
    rrule: string, dtstartMs: number): Promise<boolean> {
    const row: LocalEvent | null = await EventDb.queryById(context, localId);
    if (row === null || row.kind !== 'todo') {
      LogUtil.write(`待办循环设置失败：行不存在或不是待办 id=${localId}`);
      return false;
    }
    if (row.href === '' || row.remotePath === '') {
      LogUtil.write(`待办循环设置失败：缺少服务器路径 id=${localId}`);
      return false;
    }
    const acc: DavAccount | null = await TodoService.findAccount(context, row.href);
    if (acc === null) {
      LogUtil.write(`待办循环设置失败：找不到所属账号`);
      return false;
    }
    const idx: number = acc.calendarHrefs.indexOf(row.href);
    if (idx >= 0 && acc.calendarWritable.length > idx && acc.calendarWritable[idx] === '0') {
      LogUtil.write(`待办循环设置失败：该日历本只读 id=${localId}`);
      return false;
    }
    const auth: string = DavClient.authHeader(acc.username, acc.password);
    const url: string = row.href.endsWith('/') ? row.href + row.remotePath
      : `${row.href}/${row.remotePath}`;
    const dueMs: number = row.startTime > 0 ? row.startTime : 0;
    const base: number = dtstartMs > 0 ? dtstartMs : (dueMs > 0 ? dueMs : Date.now());
    try {
      const original: string = await DavClient.getRawStrict(url, auth);
      if (!original.toUpperCase().includes('BEGIN:VTODO')) {
        LogUtil.write(`待办循环设置失败：服务器内容不是 VTODO id=${localId}`);
        return false;
      }
      const updated: string = IcsUtil.rewriteTodoRecurrence(
        original, row.uid, rrule, base, dueMs);
      const newEtag: string = await DavClient.putEvent(url, auth, updated);
      await EventDb.updateTodoRecurrence(context, localId, rrule.trim(), base, newEtag);
      LogUtil.write(`待办循环设置成功 id=${localId} rule=${rrule === '' ? '(取消)' : rrule}`);
      return true;
    } catch (err) {
      if (err instanceof DavHttpError) {
        LogUtil.write(`待办循环设置失败 HTTP ${(err as DavHttpError).status} id=${localId}`);
      } else {
        LogUtil.write(`待办循环设置失败 id=${localId} ${(err as BusinessError).message ?? ''}`);
      }
      return false;
    }
  }

  /**
   * 循环任务"完成一轮"：把 DUE 推进到下一个周期，并保持未完成。
   *
   * 与 setCompleted 的区别：
   *   · 非循环 → 走 setCompleted（置 COMPLETED，永久结束）
   *   · 循环   → 走这里（DUE += 一个周期，STATUS 保持 NEEDS-ACTION）
   *
   * @returns 推进后的新 DUE（毫秒）；失败返回 0
   */
  static async completeRecurringRound(context: common.Context, localId: number): Promise<number> {
    const row: LocalEvent | null = await EventDb.queryById(context, localId);
    if (row === null || row.kind !== 'todo' || row.rrule.trim() === '') {
      return 0;
    }
    if (row.href === '' || row.remotePath === '') {
      return 0;
    }
    const acc: DavAccount | null = await TodoService.findAccount(context, row.href);
    if (acc === null) {
      return 0;
    }
    const idx: number = acc.calendarHrefs.indexOf(row.href);
    if (idx >= 0 && acc.calendarWritable.length > idx && acc.calendarWritable[idx] === '0') {
      return 0;
    }
    // 从 FREQ 取周期，推下一个基准
    const freq: string = IcsUtil.freqOfRrule(row.rrule);
    // 基准优先用 DTSTART（真正的重复基准），没有则用当前 DUE
    const base: number = row.dtstart > 0 ? row.dtstart : row.startTime;
    const nextBase: number = IcsUtil.incForFreq(freq, base);
    // 保留"截止 = 基准 + N"的偏移（原任务若是 09:00 截止，下一次还是 09:00）
    const offset: number = row.startTime > 0 && row.dtstart > 0 ? row.startTime - row.dtstart : 0;
    const nextDue: number = nextBase + offset;

    const auth: string = DavClient.authHeader(acc.username, acc.password);
    const url: string = row.href.endsWith('/') ? row.href + row.remotePath
      : `${row.href}/${row.remotePath}`;
    try {
      const original: string = await DavClient.getRawStrict(url, auth);
      // 先把状态复位成未完成，再把基准与截止推到下一轮
      let updated: string = IcsUtil.rewriteTodoCompletion(original, row.uid, false);
      updated = IcsUtil.rewriteTodoRecurrence(updated, row.uid, row.rrule, nextBase, nextDue);
      const newEtag: string = await DavClient.putEvent(url, auth, updated);
      await EventDb.updateTodoAfterRound(context, localId, nextBase, nextDue, newEtag);
      LogUtil.write(`循环待办推进到下一轮 id=${localId}（标题已脱敏）`);
      return nextDue > 0 ? nextDue : nextBase;
    } catch (err) {
      if (err instanceof DavHttpError) {
        LogUtil.write(`循环待办推进失败 HTTP ${(err as DavHttpError).status} id=${localId}`);
      } else {
        LogUtil.write(`循环待办推进失败 id=${localId} ${(err as BusinessError).message ?? ''}`);
      }
      return 0;
    }
  }

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