// entry/src/main/ets/common/ContactService.ets
// CardDAV 联系人同步服务
//
// 职责边界：
//   - 与远端交互（PROPFIND 发现地址簿、REPORT 拉 vCard、PUT 回写、DELETE 删除）
//   - 落到 ContactDb 本地缓存
//   - 与**系统通讯录**（@ohos.contact）同步：把 vCard 写进系统通讯录，让用户能在
//     系统电话/联系人 App 里直接看到并拨号；系统侧改动也回写远端
//
// 为什么必须走系统通讯录：鸿蒙没有"给第三方 App 单独一个通讯录界面"的需求场景，
// 用户真正要的是「拨号时能搜到这个联系人」。只在本 App 内做一个列表，
// 等于把联系人关在笼子里 —— 与 CalDAV 侧镜像到系统日历是同一个思路。
//
// 与 CalDAV 侧的差异（重要）：
//   联系人**没有**"系统通讯录不存在对应 API"的技术限制 —— @ohos.contact 是公开
//   三方能力（需 READ_CONTACTS / WRITE_CONTACTS，均 user_grant）。
//   所以这里是真双向同步，不是单向镜像。
import { common, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import contact from '@ohos.contact';
import { BusinessError } from '@kit.BasicServicesKit';
import { DavAccount, AccountStore, TYPE_CARDDAV } from './AccountStore';
import { DavClient, DavCardDavClient, DavAddressBookEntry, DavAddressBookDiscovery,
  DavHttpError, RemoteItem } from './DavClient';
import { VCardContact, VCardPhone, VCardEmail, VCardUtil } from './VCardUtil';
import { ContactDb, ContactRow, PhoneJson, EmailJson } from './ContactDb';
import { LogUtil } from './LogUtil';

/** 单个地址簿的同步结果 */
export class BookSyncResult {
  bookKey: string = '';
  bookName: string = '';
  remoteCount: number = 0;
  added: number = 0;
  updated: number = 0;
  deleted: number = 0;
  unchanged: number = 0;
  failed: number = 0;
}

/** 整账号同步结果 */
export class ContactSyncResult {
  ok: boolean = true;
  message: string = '';
  books: BookSyncResult[] = [];
  total: number = 0;
  /** 反向同步：从系统通讯录推到远端的条数 */
  pushedUp: number = 0;
  /** 反向同步：系统侧改动与远端改动冲突、放弃上行的条数 */
  conflicts: number = 0;
}

/** 单条联系人反向同步的判定结果 */
class SysDiff {
  /** 系统侧是否有实际改动 */
  changed: boolean = false;
  /** 显示名 */
  name: string = '';
}

export class ContactService {
  /**
   * 通讯录权限是否已授予。
   * 联系人同步依赖系统通讯录，未授权时仍允许"仅在 App 内查看"，
   * 但必须明确告知用户——否则用户会以为同步成功了却拨号找不到人。
   */
  /**
   * 通讯录能力状态。
   *
   * 🔴 为什么需要这套检测（2026-11-10 实测）：
   *   `ohos.permission.READ_CONTACTS` / `WRITE_CONTACTS` 在系统权限表里是
   *   **availableLevel = system_basic**，普通应用（APL=normal）**装机就会被拒**：
   *       error: install failed due to grant request permissions failed.
   *       PermissionName: ohos.permission.READ_CONTACTS  (code 9568289)
   *   已用对照实验确认：manifest 里去掉这两个权限 → 同一个包立刻能装。
   *
   *   这与 #7 记录的 VTODO 限制是同一类问题 —— **平台级门槛，不是代码没写对**。
   *
   * ⇒ 所以默认构建**不声明**这两个权限，应用走「仅在 App 内查看」模式；
   *    另出「完整版」构建（带 ACL 的 profile + 声明权限）供有资质时使用。
   *    运行期用本状态区分两种构建，避免把"装不上"变成"装上但崩"。
   */
  static readonly CONTACT_PERMS: Permissions[] = [
    'ohos.permission.READ_CONTACTS',
    'ohos.permission.WRITE_CONTACTS'
  ];

  /** 能力探测结果缓存（进程内；权限状态变化需重启应用或手动 refresh） */
  private static permState: string = 'unknown'; // unknown | granted | denied | unsupported

  /**
   * 探测本构建是否具备写入系统通讯录的能力。
   *
   * 返回 'unsupported' 的判据＝**清单里根本没声明该权限**。
   * 用 checkAccessToken 无法区分"没声明"和"声明了但被拒"（都返回未授权），
   * 所以这里直接尝试一次真实调用：没声明权限时系统会抛
   * 201（权限校验失败）这类错误，据此判定"本构建不支持"。
   */
  static async detectContactCapability(context: common.Context): Promise<string> {
    if (ContactService.permState !== 'unknown') {
      return ContactService.permState;
    }
    try {
      // 先看是否已授权（声明了且用户同意）
      const tokenId: number = context.applicationInfo.accessTokenId;
      const ctrl = abilityAccessCtrl.createAtManager();
      let allGranted: boolean = true;
      for (const p of ContactService.CONTACT_PERMS) {
        const st: abilityAccessCtrl.GrantStatus = await ctrl.checkAccessToken(tokenId, p);
        if (st !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          allGranted = false;
          break;
        }
      }
      if (allGranted) {
        ContactService.permState = 'granted';
        return ContactService.permState;
      }
      // 未授权 → 用一个"零副作用"的查询探一下：权限没声明时这里会抛错
      const attrs = new contact.ContactAttributes();
      attrs.attributes = [contact.Attribute.ATTR_NAME];
      try {
        await new Promise<void>((resolve, reject) => {
          contact.queryContacts(context, attrs, (err: BusinessError) => {
            if (err !== undefined && err !== null && err.code !== 0) {
              reject(err);
            } else {
              resolve();
            }
          });
        });
        // 没抛错但 checkAccessToken 说没授权 → 属"声明了且可申请"
        ContactService.permState = 'denied';
      } catch (err) {
        const e = err as BusinessError;
        // 201 = 权限校验失败（未在清单声明）；其它错误按"不支持"处理更安全
        LogUtil.write(`通讯录查询探测失败（code=${e.code}）：判定本构建不含通讯录权限`);
        ContactService.permState = 'unsupported';
      }
      return ContactService.permState;
    } catch (err) {
      LogUtil.write(`通讯录能力探测异常：${(err as BusinessError).message}`);
      ContactService.permState = 'unsupported';
      return ContactService.permState;
    }
  }

  /** 清掉缓存，强制重新探测（用户在设置里改过权限后调用） */
  static resetCapability(): void {
    ContactService.permState = 'unknown';
  }

  /** 是否具备"写入系统通讯录"的能力（已授权） */
  static async hasContactPermission(context: common.Context): Promise<boolean> {
    const st: string = await ContactService.detectContactCapability(context);
    return st === 'granted';
  }

  /**
   * 请求通讯录读写权限。
   * ⚠️ 本构建未声明权限时必定失败 —— 这不是 bug，是 system_basic 门槛。
   * 调用方应先用 detectContactCapability 判断，'unsupported' 时不要调这里。
   */
  static async requestContactPermission(context: common.Context): Promise<boolean> {
    try {
      const ctrl = abilityAccessCtrl.createAtManager();
      const res = await ctrl.requestPermissionsFromUser(
        context as common.UIAbilityContext, ContactService.CONTACT_PERMS);
      let ok: boolean = true;
      for (const code of res.authResults) {
        if (code !== 0) {
          ok = false;
          break;
        }
      }
      ContactService.permState = ok ? 'granted' : 'denied';
      return ok;
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`申请通讯录权限失败（本构建可能未声明该权限）：${e.code} ${e.message}`);
      ContactService.permState = 'unsupported';
      return false;
    }
  }

  /**
   * 自动发现 CardDAV 地址簿家目录。
   * 用户填的地址可能差一层（填域名、填 /carddav、填到具体地址簿），
   * 依次尝试候选路径，第一个能列出地址簿的就用。
   */
  static async discoverAddressBooks(serverUrl: string, username: string,
    auth: string): Promise<DavAddressBookDiscovery> {
    const candidates: string[] = DavCardDavClient.addressBookCandidates(serverUrl, username);
    LogUtil.write(`CardDAV 发现：共 ${candidates.length} 个候选端点`);
    let last: DavAddressBookDiscovery = new DavAddressBookDiscovery();
    for (const url of candidates) {
      try {
        const d: DavAddressBookDiscovery = await DavCardDavClient.listAddressBooks(url, auth);
        LogUtil.write(`  候选 ${url} → ${d.statusCode}，地址簿 ${d.entries.length} 个`);
        last = d;
        if (d.statusCode === 207 || d.statusCode === 200) {
          if (d.entries.length > 0) {
            LogUtil.write(`✅ 地址簿家目录确定为：${url}`);
            return d;
          }
        }
        if (d.statusCode === 401) {
          // 凭据问题，再试别的路径没意义
          return d;
        }
      } catch (err) {
        LogUtil.write(`  候选 ${url} 异常：${(err as BusinessError).message}`);
      }
    }
    return last;
  }

  /**
   * 同步单个 CardDAV 账号。
   *
   * 策略：全量比对 + 增量写库
   *   - 拉全部资源（含 ETag + vCard 正文）—— 联系人量级小（几百条），不值得做分页
   *   - ETag 相同 → 跳过解析（unchanged）
   *   - 远端有、本地无 → 新增，并写进系统通讯录
   *   - 远端有、本地有 → 更新（本地 dirty 时保留本地改动，跳过覆盖）
   *   - 本地有、远端无 → 删除（远端是权威）
   */
  static async syncAccount(context: common.Context, acc: DavAccount,
    injectSystemContacts: boolean = true): Promise<ContactSyncResult> {
    const res = new ContactSyncResult();
    if (acc.type !== TYPE_CARDDAV) {
      res.ok = false;
      res.message = '不是 CardDAV 账号';
      return res;
    }
    const auth: string = DavClient.authHeader(acc.username, acc.password);
    const books: BookSyncResult[] = [];

    const hrefs: string[] = acc.calendarHrefs;
    const names: string[] = acc.calendarNames;
    if (hrefs.length === 0) {
      res.ok = false;
      res.message = '该账号未勾选任何地址簿';
      return res;
    }

    // 读已有系统联系人映射，避免循环内 N 次全量 queryAll 系统通讯录
    let permOk: boolean = false;
    const sysByName: Map<string, contact.Contact> = new Map();
    if (injectSystemContacts) {
      permOk = await ContactService.hasContactPermission(context);
      if (!permOk) {
        LogUtil.write('⚠️ 无通讯录权限：本轮仅更新 App 内缓存，不写入系统通讯录');
      } else {
        try {
          const allSys: contact.Contact[] = await ContactService.queryAll(context);
          for (const sc of allSys) {
            const nm: string = ContactService.sysDisplayName(sc);
            if (nm !== '' && sc.key !== undefined && sc.key !== '' && !sysByName.has(nm)) {
              sysByName.set(nm, sc);
            }
          }
        } catch (_err) {
          // 读取失败时降级单条查询
        }
      }
    }

    for (let i = 0; i < hrefs.length; i++) {
      const bookHref: string = hrefs[i];
      const bookKey: string = DavClient.normalizeHref(bookHref);
      const bookName: string = i < names.length ? names[i] : bookKey;
      const br = new BookSyncResult();
      br.bookKey = bookKey;
      br.bookName = bookName;
      try {
        const items: RemoteItem[] = await DavCardDavClient.reportCards(bookHref, auth);
        br.remoteCount = items.length;
        // 本地现有（该地址簿，不读 raw 大字段）
        const localRows: ContactRow[] = await ContactDb.listByBookForSync(context, bookKey);
        const localByHref: Map<string, ContactRow> = new Map<string, ContactRow>();
        for (const r of localRows) {
          localByHref.set(r.href, r);
        }
        const seenHrefs: Set<string> = new Set<string>();

        for (const item of items) {
          seenHrefs.add(item.href);
          const ex: ContactRow | undefined = localByHref.get(item.href);
          if (ex !== undefined && ex.etag === item.etag && item.etag !== '') {
            br.unchanged++;
            continue;
          }
          // 本地有未推送改动 → 不覆盖（本地优先，等推送后再以远端回写为准）
          if (ex !== undefined && ex.dirty === 1) {
            br.unchanged++;
            continue;
          }
          const c: VCardContact | null = VCardUtil.parse(item.ics, item.href, item.etag);
          if (c === null) {
            br.failed++;
            LogUtil.write(`  跳过无法解析的资源：${item.href}`);
            continue;
          }
          c.bookHref = bookHref;
          const isNew: boolean = ex === undefined;
          await ContactDb.upsert(context, c, bookKey, item.etag, ex ?? null);
          if (isNew) {
            br.added++;
          } else {
            br.updated++;
          }
          // 写进系统通讯录（传入系统联系人缓存避免重复全量查询）
          if (permOk) {
            await ContactService.pushToSystem(context, c, bookKey, sysByName, ex);
          }
        }

        // 远端已不存在 → 批量从本地移除
        const toRemove: string[] = [];
        for (const r of localRows) {
          if (!seenHrefs.has(r.href)) {
            toRemove.push(r.href);
          }
        }
        if (toRemove.length > 0) {
          await ContactDb.removeByHrefs(context, toRemove);
          br.deleted = toRemove.length;
        }
        LogUtil.write(`地址簿「${bookName}」：远端 ${br.remoteCount}，新增 ${br.added}，`
          + `更新 ${br.updated}，删除 ${br.deleted}，不变 ${br.unchanged}，失败 ${br.failed}`);
      } catch (err) {
        const e = err as BusinessError;
        br.failed++;
        LogUtil.write(`地址簿「${bookName}」同步失败：${e.message}`);
        if (e instanceof DavHttpError && e.status === 401) {
          res.ok = false;
          res.message = '服务器拒绝凭据（401）：请检查用户名与密码';
          books.push(br);
          res.books = books;
          return res;
        }
      }
      books.push(br);
    }

    // 远端拉完之后，再看系统通讯录有没有本地改动需要上行
    if (permOk) {
      try {
        const up = await ContactService.syncFromSystem(context, hrefs, auth);
        res.pushedUp = up.pushed;
        res.conflicts = up.conflicts;
      } catch (err) {
        LogUtil.write(`反向同步异常（不影响下行结果）：${(err as BusinessError).message}`);
      }
    }

    res.books = books;
    res.total = await ContactDb.count(context);
    res.message = `同步完成，共 ${res.total} 位联系人`;
    return res;
  }

  /**
   * ⭐ 反向同步：系统通讯录 → 本地库 → 远端。
   *
   * 只处理**已关联 sys_key** 的联系人。为什么不去发现"系统里新加的联系人"：
   * 用户手机通讯录里有大量私人联系人（家人、同事、快递…），
   * 盲目上传到 CardDAV 服务器既侵犯隐私也可能炸掉服务器配额。
   * 要新增联系人请走 App 内「新建」。
   *
   * 冲突策略：远端 ETag 变化 + 系统侧也变化 → **远端优先**，
   * 只记 conflicts 计数并提示用户，不做自动合并（自动合并容易丢数据）。
   */
  static async syncFromSystem(context: common.Context, bookHrefs: string[],
    auth: string): Promise<Record<string, number>> {
    const out: Record<string, number> = { 'pushed': 0, 'conflicts': 0 };
    // 收集本账号已关联系统联系人的本地行
    const rows: ContactRow[] = await ContactDb.listAll(context);
    const bookKeys: Set<string> = new Set<string>();
    for (const h of bookHrefs) {
      bookKeys.add(DavClient.normalizeHref(h));
    }
    const linked: ContactRow[] = rows.filter((r: ContactRow): boolean =>
      r.sysKey !== '' && r.deleted === 0 && bookKeys.has(r.bookKey));
    if (linked.length === 0) {
      return out;
    }
    LogUtil.write(`反向同步：检查 ${linked.length} 位已关联系统联系人的改动`);

    for (const row of linked) {
      try {
        // 读系统侧当前状态
        let sys: contact.Contact | null = null;
        try {
          sys = await contact.queryContact(context, row.sysKey);
        } catch (err) {
          // 系统侧被删了 → 只清关联，不删远端（避免误删服务器数据）
          LogUtil.write(`系统联系人已不存在「${row.displayName}」，清除关联（保留远端）`);
          await ContactDb.setSysKey(context, row.id, '');
          continue;
        }
        if (sys === null) {
          await ContactDb.setSysKey(context, row.id, '');
          continue;
        }
        const sysModel: VCardContact = ContactService.fromSystem(sys);
        const diff: SysDiff = ContactService.diffWithRow(row, sysModel);
        if (!diff.changed) {
          continue;
        }
        // 有改动 → 判断远端是否也被改过（查单个资源 etag，不拉全簿）
        const remoteEtag: string = await DavCardDavClient.getResourceEtag(row.href, auth);
        if (remoteEtag !== '' && row.etag !== '' && remoteEtag !== row.etag) {
          // 两边都改了 → 保守：远端优先，只计数
          out['conflicts'] = (out['conflicts'] ?? 0) + 1;
          LogUtil.write(`冲突：远端与系统都改了「${diff.name}」，按远端优先，跳过上行`);
          continue;
        }
        // 远端没变 → 用系统侧的值覆盖本地，然后走正常推送
        await ContactService.applySysChanges(context, row, sysModel);
        const ok: boolean = await ContactService.pushContact(context, row.id);
        if (ok) {
          out['pushed'] = (out['pushed'] ?? 0) + 1;
          LogUtil.write(`已上行系统通讯录改动「${diff.name}」`);
        }
      } catch (err) {
        LogUtil.write(`反向同步单条失败「${row.displayName}」：${(err as BusinessError).message}`);
      }
    }
    LogUtil.write(`反向同步完成：上行 ${out['pushed']} 条，冲突跳过 ${out['conflicts']} 条`);
    return out;
  }

  /**
   * 比较本地库行与系统联系人，判断系统侧有没有实质改动。
   * 只比对本应用建模的字段（姓名/公司/职位/备注/电话/邮箱），
   * 头像、生日等系统里能填但这里不建模的字段不参与比较 ——
   * 否则用户动一下头像就会被误判成"改动"并上传。
   */
  private static diffWithRow(row: ContactRow, sys: VCardContact): SysDiff {
    const d = new SysDiff();
    d.name = sys.displayName !== '' ? sys.displayName : row.displayName;
    if (sys.displayName !== row.displayName) {
      d.changed = true;
      return d;
    }
    if (sys.org !== row.org || sys.title !== row.title || sys.note !== row.note) {
      d.changed = true;
      return d;
    }
    const localPhones: string[] = ContactDb.parsePhonesOf(row.phonesJson)
      .map((p): string => p.value);
    const sysPhones: string[] = sys.phones.map((p): string => p.value);
    if (ContactService.normSet(localPhones) !== ContactService.normSet(sysPhones)) {
      d.changed = true;
      return d;
    }
    const localEmails: string[] = ContactDb.parseEmailsOf(row.emailsJson)
      .map((e): string => e.value);
    const sysEmails: string[] = sys.emails.map((e): string => e.value);
    if (ContactService.normSet(localEmails) !== ContactService.normSet(sysEmails)) {
      d.changed = true;
    }
    return d;
  }

  /** JSON 字符串数组 → string[]（解析失败返回空） */
  private static parseJsonArray(json: string): string[] {
    if (json === '') {
      return [];
    }
    try {
      return JSON.parse(json) as string[];
    } catch (err) {
      return [];
    }
  }

  /**
   * 归一化成可比较的字符串：去空白、去空项、排序。
   * 顺序不同不算改动（用户调整电话顺序不该触发上传）。
   */
  private static normSet(list: string[]): string {
    const cleaned: string[] = list
      .map((v: string): string => v.trim())
      .filter((v: string): boolean => v !== '');
    cleaned.sort();
    return cleaned.join('|');
  }

  /** 把系统侧的值写进本地库，并标记 dirty 等待推送 */
  private static async applySysChanges(context: common.Context,
    row: ContactRow, sys: VCardContact): Promise<void> {
    const phonesJson: string = JSON.stringify(
      sys.phones.map((p): PhoneJson => {
        const j = new PhoneJson();
        j.v = p.value;
        j.t = p.type;
        return j;
      }));
    const emailsJson: string = JSON.stringify(
      sys.emails.map((e): EmailJson => {
        const j = new EmailJson();
        j.v = e.value;
        j.t = e.type;
        return j;
      }));
    const values: Record<string, string | number> = {
      'display_name': sys.displayName,
      'org': sys.org,
      'title': sys.title,
      'note': sys.note,
      'phones_json': phonesJson,
      'emails_json': emailsJson,
      'dirty': 1
    };
    await ContactDb.updateFields(context, row.id, values);
  }

  /**
   * 把一条联系人写进系统通讯录。
   *
   * 匹配策略（避免重复条目）：
   *   ① 本地行已记 sys_key → 直接更新
   *   ② 否则按「姓名 + 首个电话」在系统里查，命中就认领（处理"用户已手动存过"的情况）
   *   ③ 都没有 → 新建
   */
  static async pushToSystem(context: common.Context, c: VCardContact,
    bookKey: string, sysByNameCache?: Map<string, contact.Contact>,
    knownRow?: ContactRow): Promise<string> {
    try {
      const row: ContactRow | null = knownRow !== undefined
        ? knownRow
        : await ContactDb.findByUid(context, bookKey, c.uid);
      if (row === null) {
        return '';
      }

      // ① 已有关联 → 用 queryContact 取回**可写对象**再改
      if (row.sysKey !== '') {
        try {
          const existing: contact.Contact = await contact.queryContact(context, row.sysKey);
          ContactService.applyToSystem(existing, c);
          await contact.updateContact(context, existing);
          return row.sysKey;
        } catch (err) {
          // 系统侧被删了（或 key 失效）→ 清掉关联后走新建
          LogUtil.write(`更新系统联系人失败（可能已被删除），改为新建：${(err as BusinessError).message}`);
          await ContactDb.setSysKey(context, row.id, '');
        }
      }

      // ② 按姓名认领先前手动存过的同名联系人，避免重复条目
      if (c.displayName !== '') {
        if (sysByNameCache !== undefined) {
          const cached = sysByNameCache.get(c.displayName);
          if (cached !== undefined && cached.key !== undefined && cached.key !== '') {
            try {
              ContactService.applyToSystem(cached, c);
              await contact.updateContact(context, cached);
              await ContactDb.setSysKey(context, row.id, cached.key);
              LogUtil.write(`认领已存在的同名系统联系人「${c.displayName}」`);
              return cached.key;
            } catch (err) {
              LogUtil.write(`认领同名联系人失败：${(err as BusinessError).message}`);
            }
          }
        } else {
          const found: contact.Contact[] = await ContactService.queryAll(context);
          for (const f of found) {
            const name: string = ContactService.sysDisplayName(f);
            if (name === c.displayName && f.key !== undefined && f.key !== '') {
              try {
                ContactService.applyToSystem(f, c);
                await contact.updateContact(context, f);
                await ContactDb.setSysKey(context, row.id, f.key);
                LogUtil.write(`认领已存在的同名系统联系人「${name}」`);
                return f.key;
              } catch (err) {
                LogUtil.write(`认领同名联系人失败：${(err as BusinessError).message}`);
              }
            }
          }
        }
      }

      // ③ 新建
      const created: contact.Contact = ContactService.buildSystemContact(c);
      const newId: number = await contact.addContact(context, created);
      // addContact 只回数字 id；后续更新需要 key，回查一次
      let key: string = '';
      try {
        const all: contact.Contact[] = await ContactService.queryAll(context);
        for (const a of all) {
          if (a.id === newId && a.key !== undefined && a.key !== '') {
            key = a.key;
            break;
          }
        }
      } catch (err) {
        LogUtil.write(`回查新联系人 key 失败：${(err as BusinessError).message}`);
      }
      await ContactDb.setSysKey(context, row.id, key);
      return key;
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`写入系统通讯录失败「${c.displayName}」：${e.code} ${e.message}`);
      return '';
    }
  }

  /** 查全部联系人（只取姓名/电话/邮箱/公司/备注这几项，避免拉头像等大字段） */
  private static async queryAll(context: common.Context): Promise<contact.Contact[]> {
    const attrs = new contact.ContactAttributes();
    attrs.attributes = [
      contact.Attribute.ATTR_NAME,
      contact.Attribute.ATTR_PHONE,
      contact.Attribute.ATTR_EMAIL,
      contact.Attribute.ATTR_ORGANIZATION
    ];
    // ⚠️ (context, attrs) 这个重载在 SDK 26 里与"已废弃的 callback 版"签名冲突，
    //    Promise 版解析不明确 → 编译报 "No overload matches"。用 callback 包 Promise 最稳。
    return await new Promise<contact.Contact[]>((resolve, reject) => {
      contact.queryContacts(context, attrs,
        (err: BusinessError, data: contact.Contact[]) => {
          if (err !== undefined && err !== null && err.code !== 0) {
            reject(err);
          } else {
            resolve(data ?? []);
          }
        });
    });
  }

  /** 系统联系人的显示名：优先 Name.fullName，回退 名+姓 */
  private static sysDisplayName(sys: contact.Contact): string {
    if (sys.name === undefined || sys.name === null) {
      return '';
    }
    if (sys.name.fullName !== undefined && sys.name.fullName !== '') {
      return sys.name.fullName;
    }
    const g: string = sys.name.givenName ?? '';
    const f: string = sys.name.familyName ?? '';
    return VCardUtil.joinName(g, f);
  }

  /** 把本地模型套到一个**已存在**的系统 Contact 上（原地改，保留其 key/id） */
  private static applyToSystem(target: contact.Contact, c: VCardContact): void {
    const nm = new contact.Name();
    nm.familyName = c.familyName;
    nm.givenName = c.givenName;
    nm.middleName = c.middleName;
    nm.namePrefix = c.prefix;
    nm.nameSuffix = c.suffix;
    nm.fullName = c.displayName;
    target.name = nm;

    const phones: contact.PhoneNumber[] = [];
    for (const p of c.phones) {
      const pn = new contact.PhoneNumber();
      pn.phoneNumber = p.value;
      pn.labelName = ContactService.phoneLabel(p.type);
      phones.push(pn);
    }
    target.phoneNumbers = phones;

    const emails: contact.Email[] = [];
    for (const e of c.emails) {
      const em = new contact.Email();
      em.email = e.value;
      em.labelName = ContactService.emailLabel(e.type);
      emails.push(em);
    }
    target.emails = emails;

    if (c.org !== '' || c.title !== '') {
      const org = new contact.Organization();
      org.name = c.org;
      org.title = c.title;
      target.organization = org;
    }
    if (c.note !== '') {
      const note = new contact.Note();
      note.noteContent = c.note;
      target.note = note;
    }
  }

  /** 本地模型 → **全新**系统 Contact（新建用；更新走 applyToSystem） */
  private static buildSystemContact(c: VCardContact): contact.Contact {
    const out = new contact.Contact();
    ContactService.applyToSystem(out, c);
    return out;
  }

  /** vCard 的 TEL 类型 → 系统通讯录 labelName */
  private static phoneLabel(type: string): string {
    switch (type) {
      case 'CELL':
        return '手机';
      case 'WORK':
        return '工作';
      case 'HOME':
        return '住宅';
      case 'FAX':
        return '传真';
      case 'PAGER':
        return '寻呼机';
      default:
        return '其他';
    }
  }

  private static emailLabel(type: string): string {
    switch (type) {
      case 'WORK':
        return '工作';
      case 'HOME':
        return '个人';
      default:
        return '其他';
    }
  }

  /** 读系统通讯录里的一个联系人 → 本地模型（反向同步用） */
  static fromSystem(sys: contact.Contact): VCardContact {
    const c = new VCardContact();
    c.displayName = ContactService.sysDisplayName(sys);
    if (sys.name !== undefined && sys.name !== null) {
      c.familyName = sys.name.familyName ?? '';
      c.givenName = sys.name.givenName ?? '';
      c.middleName = sys.name.middleName ?? '';
      c.prefix = sys.name.namePrefix ?? '';
      c.suffix = sys.name.nameSuffix ?? '';
    }
    if (sys.phoneNumbers !== undefined) {
      for (const p of sys.phoneNumbers) {
        const ph = new VCardPhone();
        ph.value = p.phoneNumber ?? '';
        if (ph.value !== '') {
          c.phones.push(ph);
        }
      }
    }
    if (sys.emails !== undefined) {
      for (const e of sys.emails) {
        const em = new VCardEmail();
        em.value = e.email ?? '';
        if (em.value !== '') {
          c.emails.push(em);
        }
      }
    }
    if (sys.organization !== undefined && sys.organization !== null) {
      c.org = sys.organization.name ?? '';
      c.title = sys.organization.title ?? '';
    }
    if (sys.note !== undefined && sys.note !== null) {
      c.note = sys.note.noteContent ?? '';
    }
    return c;
  }

  /**
   * 本地编辑后推送回远端。
   * 沿用 CalDAV 侧的"原文就地改"思路：在 raw 上改字段，其他属性原样保留。
   */
  static async pushContact(context: common.Context, rowId: number): Promise<boolean> {
    const row: ContactRow | null = await ContactDb.findById(context, rowId);
    if (row === null) {
      LogUtil.write(`推送联系人失败：本地无 id=${rowId}`);
      return false;
    }
    // 找到所属账号（凭据）
    const accounts: DavAccount[] = await AccountStore.loadAll(context);
    let acc: DavAccount | undefined = undefined;
    for (const a of accounts) {
      if (a.type !== TYPE_CARDDAV) {
        continue;
      }
      for (const h of a.calendarHrefs) {
        if (DavClient.normalizeHref(h) === row.bookKey) {
          acc = a;
          break;
        }
      }
      if (acc !== undefined) {
        break;
      }
    }
    if (acc === undefined) {
      LogUtil.write(`推送联系人失败：找不到 bookKey=${row.bookKey} 所属账号`);
      return false;
    }
    const auth: string = DavClient.authHeader(acc.username, acc.password);

    try {
      if (row.deleted === 1) {
        await DavClient.deleteRemote(row.href, auth);
        await ContactDb.hardDelete(context, row.id);
        LogUtil.write(`已删除远端联系人 ${row.displayName}`);
        return true;
      }
      const c: VCardContact = ContactDb.toModel(row);
      let raw: string = row.raw !== '' ? row.raw : VCardUtil.build(c, row.uid);
      // 就地改关键字段
      raw = VCardUtil.setField(raw, 'FN', c.displayName);
      // ⚠️ N 是五段结构，必须用 setStructuredField（逐段转义、段间裸分号）。
      //    用 setField 会把分号转义成 \\;，服务端把整串当"姓"，名字段全丢。
      raw = VCardUtil.setStructuredField(raw, 'N',
        [c.familyName, c.givenName, c.middleName, c.prefix, c.suffix]);
      // ORG 也是多段结构（公司;部门），这里只建模第一级，
      // 用单段 setStructuredField 保证 org 内部的分号被正确转义
      raw = c.org === '' ? VCardUtil.setField(raw, 'ORG', '')
        : VCardUtil.setStructuredField(raw, 'ORG', [c.org]);
      raw = VCardUtil.setField(raw, 'TITLE', c.title);
      raw = VCardUtil.setField(raw, 'NOTE', c.note);
      raw = VCardUtil.setField(raw, 'REV', VCardUtil.utcStamp());
      raw = VCardUtil.setMulti(raw, 'TEL', c.phones.map((p): string => p.value),
        c.phones.map((p): string => p.type !== '' ? `TYPE=${p.type}` : ''));
      raw = VCardUtil.setMulti(raw, 'EMAIL', c.emails.map((e): string => e.value),
        c.emails.map((e): string => e.type !== '' ? `TYPE=${e.type}` : ''));

      // 新联系人（href 为空）→ 拼一个资源地址
      let targetUrl: string = row.href;
      if (targetUrl === '') {
        const bookHref: string = ContactService.bookHrefOf(acc, row.bookKey);
        if (bookHref === '') {
          LogUtil.write('推送联系人失败：无地址簿 URL');
          return false;
        }
        const base: string = bookHref.endsWith('/') ? bookHref : bookHref + '/';
        targetUrl = base + encodeURIComponent(row.uid) + '.vcf';
      }
      const etag: string = await DavCardDavClient.putCard(targetUrl, auth, raw);
      await ContactDb.setRawAndClean(context, row.id, raw, etag);
      LogUtil.write(`已推送联系人「${c.displayName}」→ ${etag === '' ? '(无etag)' : 'ok'}`);
      return true;
    } catch (err) {
      const e = err as BusinessError;
      LogUtil.write(`推送联系人失败「${row.displayName}」：${e.message}`);
      return false;
    }
  }

  /** 从账号里按 normalizeHref 找回原始 bookHref（相对/绝对两种写法都要兼容） */
  private static bookHrefOf(acc: DavAccount, bookKey: string): string {
    for (const h of acc.calendarHrefs) {
      if (DavClient.normalizeHref(h) === bookKey) {
        return h;
      }
    }
    return '';
  }
}