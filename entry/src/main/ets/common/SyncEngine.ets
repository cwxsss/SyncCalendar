// entry/src/main/ets/common/SyncEngine.ets
// 双向同步引擎：先推本地修改（PUT/DELETE），再拉远端变更（REPORT + etag 增量）
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DavAccount, AccountStore } from './AccountStore';
import { EventDb, LocalEvent, RemoteEvent } from './EventDb';
import { IcsUtil } from './IcsUtil';
import { DavClient, DavColorEntry, DavHttpError, RemoteItem } from './DavClient';
import { LogUtil } from './LogUtil';
import { AppSettings } from './AppSettings';
import { SystemCalendarMirror } from './SystemCalendarMirror';

/**
 * ⭐ "已有同步任务正在进行"专用错误类型。
 *
 * 背景（用户反馈）：后台同步进行中时，用户再点「手动同步」或在账号管理点「保存并同步」，
 * 会并发触发第二轮同步；互斥锁把它拦下来，但那时抛的是普通 Error → 界面统一显示
 * "同步失败：该账号正在同步中，请稍后再试"。用户看到"失败"会误以为出了问题。
 *
 * 正确做法：并发被拦下时**不是失败**，而应提示"有同步任务正在进行中，请耐心等待"。
 * 因此用这个独立类型与真正的同步故障区分开，界面据此改提示语（而非报错）。
 */
export class SyncBusyError extends Error {
  constructor() {
    super('SYNC_BUSY');
  }
}

export class SyncEngine {
  /** 正在同步中的账号 id → 开始时间：防止超时后的"僵尸同步"与新一轮同步并发写库 */
  private static activeSyncs: Map<string, number> = new Map();
  /** 互斥锁最长持有时间：超过视为异常残留（如进程挂起后网络停摆），允许抢占 */
  private static readonly LOCK_STALE_MS: number = 15 * 60 * 1000;

  /** 某账号当前是否正在同步（供界面判断，不触发任何操作） */
  static isSyncing(accId: string): boolean {
    const heldSince: number | undefined = SyncEngine.activeSyncs.get(accId);
    if (heldSince === undefined) {
      return false;
    }
    return Date.now() - heldSince < SyncEngine.LOCK_STALE_MS;
  }

  /** 当前是否有任意账号正在同步 */
  static isAnySyncing(): boolean {
    const now: number = Date.now();
    for (const id of SyncEngine.activeSyncs.keys()) {
      const since: number | undefined = SyncEngine.activeSyncs.get(id);
      if (since !== undefined && now - since < SyncEngine.LOCK_STALE_MS) {
        return true;
      }
    }
    return false;
  }

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
        // ⭐ 抛专用类型：界面据此提示"同步进行中，请耐心等待"而非"失败"
        throw new SyncBusyError();
      }
      LogUtil.write(`同步互斥锁超时残留（账号 id=${acc.id}），强制释放并重新同步`);
    }
    SyncEngine.activeSyncs.set(acc.id, Date.now());
    const t0: number = Date.now();
    // 日志不记录账号名（用户自定义，可能含个人信息），以 id + 服务器地址定位
    LogUtil.write(`========== 同步账号 id=${acc.id} 开始：服务器 ${acc.serverUrl}，共 ${acc.calendarHrefs.length} 个日历本 ==========`);
    try {
      // ⭐ 库结构升级（recurrence_id 列）：老库里覆盖实例的该列全是 0，而被丢弃的
      //    RECURRENCE-ID 无法从本地任何字段反推 → 必须靠一次全量重拉（GET 每个 .ics）回填。
      //    不回填的后果：把某次发生改期的覆盖实例无法排除主事件在原时间的那次发生，
      //    App 与系统日历里同一日程会显示两条（幽灵日程）。
      //    ⚠️ 判据必须是**数据库里的真实状态**：内存标志会被卡片进程/进程重启吃掉
      //    （2026-09-19 实测两次同步都没触发）。回填完成后计数自然归 0，不会反复重拉。
      await EventDb.getDb(context);
      const ridMissing: number = await EventDb.countOverridesMissingRecurrenceId(context);
      if (ridMissing > 0) {
        LogUtil.write(`recurrence_id 待回填 ${ridMissing} 条覆盖实例 → 重置"一次性全量重拉"`);
        await AppSettings.resetFullRefetch(context);
      }
      // 全量重拉（升级后首次）要逐个 GET 所有资源，放宽超时到 10 分钟；常规 5 分钟
      const fullRefetch: boolean = await AppSettings.isFullRefetchPending(context);
      const timeoutMs: number = fullRefetch ? 600000 : 300000;
      // 内层任务真正结束（无论成败）才释放互斥锁；超时后它仍会在后台跑完
      const inner: Promise<number> = SyncEngine.syncAccountInner(context, acc);
      inner.catch((): void => {}).finally((): void => {
        SyncEngine.activeSyncs.delete(acc.id);
      });
      const r: number = await SyncEngine.withTimeout<number>(inner, timeoutMs);
      LogUtil.write(`同步账号 id=${acc.id} 完成：拉取 ${r} 条日程，耗时 ${Math.round((Date.now() - t0) / 1000)} 秒`);
      return r;
    } catch (err) {
      // ⭐ "正在同步中"原样抛出（界面据此提示"请耐心等待"，不当成失败）
      if (err instanceof SyncBusyError) {
        throw err;
      }
      const e = err as BusinessError;
      LogUtil.write(`同步账号 id=${acc.id} 失败：${e.message}（耗时 ${Math.round((Date.now() - t0) / 1000)} 秒）`);
      throw new Error(e.message !== '' ? e.message : `错误码 ${e.code}`);
    }
  }

  private static async syncAccountInner(context: common.Context, acc: DavAccount): Promise<number> {
    const auth: string = DavClient.authHeader(acc.username, acc.password);
    // 0) 刷新服务器端日历本颜色（每次同步都校正）
    //    ⭐ 有变化就立刻落盘：镜像 listBooks 从磁盘重新 loadAll，
    //      不落盘的话镜像 setConfig 的永远是旧颜色（系统日历颜色不跟服务器变）。
    const colorChanged: boolean = await SyncEngine.refreshCalendarColors(acc, auth);
    if (colorChanged) {
      try {
        const all: DavAccount[] = await AccountStore.loadAll(context);
        const idx: number = all.findIndex((a: DavAccount): boolean => a.id === acc.id);
        if (idx >= 0) {
          all[idx] = acc;
          await AccountStore.saveAll(context, all);
          LogUtil.write('日历本颜色/权限有变化，已落盘（镜像将使用新颜色）');
        }
      } catch (err) {
        const e = err as BusinessError;
        LogUtil.write(`颜色/权限落盘失败(不影响同步): ${e.message}`);
      }
    }
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
    // 服务器上已不存在的日历本（REPORT 404）：先跳过继续同步其它日历本，
    // 循环结束后统一从账号移除（见 removeDeadBooks）。
    // 2026-09-29 实测：服务器上删掉一个日历本后，本地仍勾选它 → 每次同步 404 →
    // 旧版直接抛错让整个账号同步失败，且后台同步每轮都失败（一天半没同步成功过）。
    const deadIdxs: number[] = [];
    for (let i = 0; i < acc.calendarHrefs.length; i++) {
      const href: string = acc.calendarHrefs[i];
      const calKey: string = `${acc.id}_${i}`;
      const calName: string = i < acc.calendarNames.length ? acc.calendarNames[i] : `日历本${i}`;
      LogUtil.write(`日历本[${i}]「${calName}」开始同步：${href}`);
      const t1: number = Date.now();
      let items: RemoteItem[] = [];
      try {
        items = await DavClient.reportEtags(href, auth);
      } catch (err) {
        if (err instanceof DavHttpError && (err as DavHttpError).status === 404) {
          LogUtil.write(`日历本[${i}]「${calName}」在服务器上已不存在(404)，本轮跳过，收尾时自动从账号移除`);
          deadIdxs.push(i);
          continue;
        }
        throw err as Error;
      }
      LogUtil.write(`日历本[${i}]「${calName}」REPORT 返回 ${items.length} 个资源`);
      // 现有行按 uid 分组（同一资源的覆盖实例共享 uid 与 etag）
      const existingRows: LocalEvent[] = await EventDb.queryByCalKey(context, calKey, 'event');
      const byUid: Map<string, LocalEvent[]> = new Map();
      // ⭐ 再按 **etag** 分组，给下面"要不要 GET 这个资源"做兜底（见 §复用判定 注释）
      const byEtag: Map<string, LocalEvent[]> = new Map();
      for (const row of existingRows) {
        SyncEngine.groupPush(byUid, row.uid, row);
        if (row.etag !== '') {
          SyncEngine.groupPush(byEtag, row.etag, row);
        }
      }
      const originMatch = /https?:\/\/[^/]+/i.exec(href);
      const origin: string = originMatch !== null ? originMatch[0] : '';
      const remote: RemoteEvent[] = [];
      let fetched: number = 0;
      let parseFail: number = 0;
      const needFetch: RemoteItem[] = [];
      let hitUid: number = 0;    // 按"资源名 = uid"命中
      let hitEtag: number = 0;   // 按 etag 内容哈希兜底命中
      for (const it of items) {
        const resUid: string = SyncEngine.resUidFromHref(it.href);
        let group: LocalEvent[] | undefined = byUid.get(resUid);
        if (group !== undefined) {
          hitUid++;
        } else if (it.etag !== '') {
          // ⭐ 复用判定（2026-10-15 修复）：**服务器不保证"资源文件名 = ICS 里的 UID"**。
          //   家书 CalDav.php:253 用 preg_replace('/[^A-Za-z0-9._-]/', '_', $uid) 生成文件名：
          //   UID `movie-188@familybook` 的资源叫 `movie-188_familybook.ics`。
          //   旧版只按资源名去 `byUid` 查 → 永远查不到 → 该资源**每轮都被判成"变了"**，
          //   于是每次都全量 GET（实测 2184 个资源 → 单次同步 200~300 秒：卡片后台同步
          //   那 9 秒窗口连一个日历本都跑不完）。
          //   etag 是**内容哈希**（服务端由正文 md5 得出）：相等即内容一致，
          //   与"资源叫什么名字"无关 —— 用它兜底既安全又与服务器实现解耦。
          group = byEtag.get(it.etag);
          if (group !== undefined) {
            hitEtag++;
          }
        }
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
      LogUtil.write(`日历本[${i}]「${calName}」复用判定：uid 命中 ${hitUid}、etag 兜底命中 ${hitEtag}、需补拉 ${needFetch.length}（共 ${items.length}）`);
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
    // 收尾：把本轮发现的"服务器上已删除"的日历本从账号移除并清理本地数据。
    // 放在循环后（而非循环中）是因为移除会让后续序号前移，循环中途改数组会打乱 calKey。
    if (deadIdxs.length > 0) {
      await SyncEngine.removeDeadBooks(context, acc, deadIdxs);
    }
    return changed;
  }

  /**
   * 从账号移除「服务器上已不存在（404）」的日历本：收窄配置、迁移序号、清理本地数据并持久化。
   * 只要有至少一个日历本保留就自动移除；若全部失效则不动配置（避免把账号清空），
   * 抛错交给上层提示用户去服务器/编辑账号处理。
   */
  private static async removeDeadBooks(context: common.Context, acc: DavAccount,
    deadIdxs: number[]): Promise<void> {
    if (deadIdxs.length >= acc.calendarHrefs.length) {
      throw new Error('该账号下所有日历本在服务器上均已不存在(404)，请检查服务器或重新编辑账号');
    }
    const deadSet: Set<number> = new Set<number>();
    for (const d of deadIdxs) {
      deadSet.add(d);
    }
    const removedHrefs: string[] = [];
    const newHrefs: string[] = [];
    const newNames: string[] = [];
    const newColors: string[] = [];
    const newWritable: string[] = [];
    for (let i = 0; i < acc.calendarHrefs.length; i++) {
      if (deadSet.has(i)) {
        removedHrefs.push(acc.calendarHrefs[i]);
        continue;
      }
      newHrefs.push(acc.calendarHrefs[i]);
      newNames.push(i < acc.calendarNames.length ? acc.calendarNames[i] : `日历本${i}`);
      newColors.push(i < acc.calendarColors.length ? acc.calendarColors[i] : '');
      newWritable.push(i < acc.calendarWritable.length ? acc.calendarWritable[i] : '1');
    }
    LogUtil.write(`自动移除 ${removedHrefs.length} 个在服务器上不存在的日历本，保留 ${newHrefs.length} 个`);
    // 1) 先按 href 删掉被移除日历本的本地行——必须在序号迁移之前，
    //    否则序号收窄后这些行会混进接替该序号的其它日历本（pruneByHrefs 注释详述）
    await EventDb.pruneByHrefs(context, acc.id, removedHrefs);
    // 2) 序号迁移：保留的日历本按原顺序收紧（旧序号 → 新序号）
    const oldHrefs: string[] = acc.calendarHrefs.slice();
    const pairs: Array<[string, string]> = [];
    let ni: number = 0;
    for (let oi = 0; oi < oldHrefs.length; oi++) {
      if (deadSet.has(oi)) {
        continue;
      }
      if (ni !== oi) {
        pairs.push([`${acc.id}_${oi}`, `${acc.id}_${ni}`]);
      }
      ni++;
    }
    if (pairs.length > 0) {
      const moved: number = await EventDb.remapCalKeys(context, pairs);
      LogUtil.write(`移除失效日历本后迁移日程 ${moved} 行（${pairs.length} 个日历本序号前移）`);
    }
    // 3) 收窄账号配置并持久化
    acc.calendarHrefs = newHrefs;
    acc.calendarNames = newNames;
    acc.calendarColors = newColors;
    acc.calendarWritable = newWritable;
    const all: DavAccount[] = await AccountStore.loadAll(context);
    const idx: number = all.findIndex((a: DavAccount): boolean => a.id === acc.id);
    if (idx >= 0) {
      all[idx] = acc;
      await AccountStore.saveAll(context, all);
    }
    // 4) 兜底：该账号下 calKey 不在有效列表的行全部清掉
    const validKeys: string[] = [];
    for (let i = 0; i < newHrefs.length; i++) {
      validKeys.push(`${acc.id}_${i}`);
    }
    await EventDb.pruneAccountEvents(context, acc.id, validKeys);
    // 5) 若被移除的日历本正是「系统日历 → CalDAV」的备份目标，当场判失效并关闭备份
    try {
      const backupCheck = await SystemCalendarMirror.checkBackupTarget(context);
      if (backupCheck.closed) {
        LogUtil.write('备份目标日历本已在服务器上删除，备份功能已自动关闭');
      }
    } catch (err) {
      // 检查失败不影响主流程
    }
  }

  /**
   * 刷新服务器端日历本颜色：PROPFIND getcolor → 按集合路径匹配更新 acc.calendarColors
   * 失败静默（颜色不影响数据正确性）
   * ⭐ 返回**是否有实际变化**（颜色或写权限）——调用方据此落盘。
   *   （0.0.9 修复：此前变化只留在内存、从不 saveAll ⇒ 镜像 listBooks 从磁盘读到的
   *    永远是旧颜色 ⇒ setConfig 旧色 ⇒ 系统日历颜色永远不跟服务器变；
   *    而账号设置页是当场 PROPFIND 的，所以"页面上是新色、系统日历是旧色"。）
   */
  static async refreshCalendarColors(acc: DavAccount, auth: string): Promise<boolean> {
    let changed: boolean = false;
    let entries: DavColorEntry[] = [];
    try {
      entries = await DavClient.propfindColors(acc.serverUrl, auth);
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`PROPFIND 颜色/权限失败(继续探测写权限): ${e.message}`);
    }
    for (let i = 0; i < acc.calendarHrefs.length; i++) {
      const target: string = acc.calendarHrefs[i];
      // 用规范化后的路径比对：兼容「绝对 URL vs 纯路径」「URL 编码差异」「尾斜杠有无」，
      // 否则新加入的日历本匹配不上 → 服务器颜色取不回来，界面只能退回调色板色（表现为"颜色不对"）
      const targetNorm: string = DavClient.normalizeHref(target);
      const found = entries.find((e: DavColorEntry): boolean =>
        DavClient.normalizeHref(e.href) === targetNorm);
      if (found !== undefined && found.color !== '') {
        while (acc.calendarColors.length <= i) {
          acc.calendarColors.push('');
          changed = true; // 长度补齐也视作变化（旧账号可能还没这一位）
        }
        if (acc.calendarColors[i] !== found.color) {
          LogUtil.write(`日历本[${i}] 颜色更新：${acc.calendarColors[i] === '' ? '(空)' : acc.calendarColors[i]} → ${found.color}`);
          changed = true;
        }
        acc.calendarColors[i] = found.color;
      } else if (found === undefined) {
        // 匹配失败不改动已有颜色（保留上次取到的值），但记录便于排查
        LogUtil.write(`日历本[${i}] 颜色未匹配：${target}（PROPFIND 返回 ${entries.length} 个集合）`);
      }
      // 回写各日历本写权限（'1'=可写 '0'=只读）
      while (acc.calendarWritable.length <= i) {
        acc.calendarWritable.push('1');
      }
      const calName: string = i < acc.calendarNames.length ? acc.calendarNames[i] : `日历本${i}`;
      let writable: string;
      if (found !== undefined && found.privilegeKnown) {
        // 服务器声明了权限：直接采用
        writable = found.writable ? '1' : '0';
        LogUtil.write(`日历本[${i}]「${calName}」写权限(privilege)：${found.writable ? '可写' : '只读'}`);
      } else {
        // 服务器未声明权限（如部分 Synology 配置）或 PROPFIND 未匹配到该本：真实写探测
        const w: boolean = await DavClient.probeWritable(target, auth);
        writable = w ? '1' : '0';
        LogUtil.write(`日历本[${i}]「${calName}」写权限(探测)：${w ? '可写' : '只读'}`);
      }
      if (acc.calendarWritable[i] !== writable) {
        changed = true;
      }
      acc.calendarWritable[i] = writable;
    }
    return changed;
  }

  /** Map<key, 行数组> 追加一行（没有该 key 就建数组） */
  private static groupPush(m: Map<string, LocalEvent[]>, key: string, row: LocalEvent): void {
    const arr: LocalEvent[] | undefined = m.get(key);
    if (arr === undefined) {
      m.set(key, [row]);
    } else {
      arr.push(row);
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
  private static resUidFromHref(href: string): string {    const segs: string[] = href.split('/').filter((s: string): boolean => s !== '');
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
    r.recurrenceId = e.recurrenceId;
    r.reminder = e.reminder;
    r.reminders = e.reminders.slice();
    return r;
  }

  /**
   * 推送指定账号日历本下的待同步事件（新建/修改 → PUT；删除 → DELETE）
   */
  static async pushDirtyForAccount(context: common.Context, acc: DavAccount, auth: string): Promise<void> {
    const dirty: LocalEvent[] = await EventDb.getDirty(context);
    const normHrefs: string[] = acc.calendarHrefs.map((h: string): string => DavClient.normalizeHref(h));
    const mine: LocalEvent[] = dirty.filter((e: LocalEvent): boolean =>
      normHrefs.includes(DavClient.normalizeHref(e.href)));
    LogUtil.write(`推送本地修改：全部待推送 ${dirty.length} 条，属于账号 id=${acc.id} 的 ${mine.length} 条`);
    // ⭐ 同一个重复系列（uid + 日历本）在一次推送里只处理一次：整份 .ics（主事件 + 各覆盖实例）
    //    一起重建后推送，避免"先 PUT 覆盖实例、后 PUT 主事件"互相覆盖。
    const pushedSeries: Set<string> = new Set<string>();
    const originMatch = /https?:\/\/[^/]+/i.exec(acc.serverUrl);
    const origin: string = originMatch !== null ? originMatch[0] : '';
    for (const e of mine) {
      // 只读日历本：推送必然 403，跳过并保留 dirty（权限恢复后可再推）
      const bookIdx: number = normHrefs.indexOf(DavClient.normalizeHref(e.href));
      if (bookIdx >= 0 && acc.calendarWritable.length > bookIdx
        && acc.calendarWritable[bookIdx] === '0') {
        LogUtil.write(`推送跳过只读日历本事件（标题已脱敏）uid=${e.uid}`);
        continue;
      }
      if (e.kind === 'todo') {
        // 待办只读：本地不会有 dirty 待办，兜底清除
        await EventDb.clearDirty(context, e.id, e.etag);
        continue;
      }
      // ⭐ 重复系列（含覆盖实例）：按 uid 取全系列行，重建整份 .ics 后一次性 PUT。
      //    旧版对"覆盖实例"直接跳过（不推送），导致 App 里的单次改期/删除无法上传到服务器；
      //    现在支持标准写法（同资源内多 VEVENT + RECURRENCE-ID）。
      const seriesKey: string = `${e.calKey}|${e.uid}`;
      if ((e.recurring || e.rrule !== '') && !pushedSeries.has(seriesKey)) {
        pushedSeries.add(seriesKey);
        await SyncEngine.pushSeries(context, acc, auth, e);
        continue;
      }
      if ((e.recurring || e.rrule !== '') && pushedSeries.has(seriesKey)) {
        continue; // 该系列已在上面整体推送过
      }
      let url: string = e.href.endsWith('/') ? e.href + e.remotePath : `${e.href}/${e.remotePath}`;
      if (!url.startsWith('http') && origin !== '') {
        url = origin + url;
      }
      try {
        if (e.deleted) {
          try {
            await DavClient.deleteRemote(url, auth);
          } catch (delErr) {
            if (delErr instanceof DavHttpError) {
              const st = (delErr as DavHttpError).status;
              if (st === 401) {
                throw delErr as Error;
              }
              if (st !== 404 && st !== 410) {
                throw delErr as Error;
              }
              LogUtil.write(`服务器上该单条资源已不存在(${st})，直接清理本地：uid=${e.uid}`);
            } else {
              throw delErr as Error;
            }
          }
          await EventDb.purge(context, e.id);
          LogUtil.write(`推送删除（标题已脱敏）uid=${e.uid} → ${url}`);
        } else {
          const ics: string = IcsUtil.build(e);
          const etag: string = await DavClient.putEvent(url, auth, ics);
          await EventDb.clearDirty(context, e.id, etag);
          LogUtil.write(`推送保存（标题已脱敏）uid=${e.uid} → ${url}（${ics.length} 字节，提醒=${e.reminders.map((n: number): string => String(n)).join('/')}分钟，VALARM=${ics.toUpperCase().includes('BEGIN:VALARM') ? '有' : '无'}）`);
        }
      } catch (err) {
        // 单条推送失败不再中断整个账号（旧行为：一条 404 就让整个账号同步失败）。
        // 401（凭据失效）例外：后续每条也必然失败，直接抛出让上层提示。
        if (err instanceof DavHttpError && (err as DavHttpError).status === 401) {
          throw err as Error;
        }
        const pe = err as Error;
        LogUtil.write(`推送单条失败(跳过，保留待推送)：uid=${e.uid} → ${pe.message}`);
      }
    }
  }

  /**
   * ⭐ 推送一个"重复系列"：取该 uid 下的主事件与全部覆盖实例，合成整份 .ics 后 PUT。
   *
   * - 主事件行若被标记删除（deleted）→ 视为"整个系列删除"，DELETE 整个资源并清掉本地该 uid 全部行。
   * - 否则重建（主事件可能带上了 EXDATE / 被截断的 UNTIL，覆盖实例带 RECURRENCE-ID），
   *   一次性 PUT 覆盖服务器上的同一资源；成功后清掉本系列全部行的 dirty。
   */
  private static async pushSeries(context: common.Context, acc: DavAccount, auth: string,
    trigger: LocalEvent): Promise<void> {
    const calKey: string = trigger.calKey;
    const uid: string = trigger.uid;
    // ⭐ 查询该 UID 下的所有行（包括被标记删除的行，以便处理整系列删除）
    const rows: LocalEvent[] = await EventDb.queryByUid(context, calKey, uid, true);
    // 主事件：优先取带 RRULE 的行；退而取最早一行
    let master: LocalEvent | null = null;
    for (const r of rows) {
      if (r.rrule !== '') {
        master = r;
        break;
      }
    }
    if (master === null && rows.length > 0) {
      master = rows[0];
    }
    if (master === null) {
      return;
    }
    const href: string = master.href;
    const path: string = master.remotePath !== '' ? master.remotePath : encodeURIComponent(uid) + '.ics';
    const originMatch = /https?:\/\/[^/]+/i.exec(href.startsWith('http') ? href : acc.serverUrl);
    const origin: string = originMatch !== null ? originMatch[0] : '';
    let url: string = href.endsWith('/') ? href + path : `${href}/${path}`;
    if (!url.startsWith('http') && origin !== '') {
      url = origin + url;
    }
    // 整个系列被删除（主事件行 deleted 或触发者标记删除且无存活 master）→ DELETE 资源 + 清掉该 uid 全部本地行
    if (master.deleted || trigger.deleted) {
      try {
        await DavClient.deleteRemote(url, auth);
      } catch (err) {
        if (err instanceof DavHttpError) {
          const st = (err as DavHttpError).status;
          if (st === 401) {
            throw err as Error;
          }
          if (st === 404 || st === 410) {
            LogUtil.write(`服务器上该重复系列已不存在(${st})，直接清理本地：uid=${uid}`);
          } else {
            LogUtil.write(`推送删除重复系列失败：uid=${uid} → ${(err as Error).message}`);
            return;
          }
        } else {
          LogUtil.write(`推送删除重复系列失败：uid=${uid} → ${(err as Error).message}`);
          return;
        }
      }
      await EventDb.purgeByUid(context, calKey, uid);
      LogUtil.write(`推送删除重复系列（标题已脱敏）uid=${uid} → ${url}`);
      return;
    }
    const overrides: LocalEvent[] = [];
    for (const r of rows) {
      if (r.id !== master.id && r.rrule === '' && r.recurrenceId > 0 && !r.deleted) {
        overrides.push(r);
      }
    }
    overrides.sort((a: LocalEvent, b: LocalEvent): number => a.recurrenceId - b.recurrenceId);
    const ics: string = IcsUtil.buildSeries(master, overrides);
    try {
      const etag: string = await DavClient.putEvent(url, auth, ics);
      // 清掉本系列存活行的 dirty；将被标记删除的覆盖行从本地物理清除
      let first: boolean = true;
      for (const r of rows) {
        if (r.deleted) {
          await EventDb.purge(context, r.id);
        } else {
          await EventDb.clearDirty(context, r.id, first ? etag : '');
        }
        first = false;
      }
      LogUtil.write(`推送重复系列（标题已脱敏）uid=${uid} → ${url}（${ics.length} 字节，覆盖实例=${overrides.length}）`);
    } catch (err) {
      if (err instanceof DavHttpError && (err as DavHttpError).status === 401) {
        throw err as Error;
      }
      LogUtil.write(`推送重复系列失败(保留待推送)：uid=${uid} → ${(err as Error).message}`);
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
    // ⭐ 顺带清理"同一资源被重复插入"的冗余行（旧版 applyRemote 判重缺陷遗留的脏数据）。
    //    纯本地去重、不推服务器；放在这里是因为它是每次同步都会经过的收尾步骤。
    try {
      const dup: number = await EventDb.dedupeDuplicateRows(context);
      if (dup > 0) {
        LogUtil.write(`清理本地重复行：${dup} 条（同一资源被插了多次）`);
      }
    } catch (err) {
      // 忽略：去重失败不影响同步
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
      // 兜底清扫：行上 href 已不属于任何已选日历本的残留行（calKey 可能因历史迁移
      // 缺陷混在有效日历本名下，calKey 维度抓不到，href 才暴露真实归属）。
      // 典型如服务器删除日历本后残留的"幽灵"数据——不清掉的话镜像会一直把它写进系统日历。
      const validHrefs: string[] = [];
      for (const a of accounts) {
        for (const h of a.calendarHrefs) {
          validHrefs.push(h);
        }
      }
      const stale: number = await EventDb.pruneStaleHrefs(context, validHrefs);
      if (stale > 0) {
        LogUtil.write(`清理失效日历本残留行：${stale} 条（href 已不属于任何已选日历本）`);
      }
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`清理孤儿日程行失败(忽略)：${e.message}`);
    }
  }
}