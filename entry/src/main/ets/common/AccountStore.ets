// entry/src/main/ets/common/AccountStore.ets
// DAV 账号持久化（加密）：
// - 账号列表（含密码）序列化为 JSON 后整体加密，存储为 caldav_vault 偏好中的 data_b64。
// - **首选 HUKS 硬件密钥库**：AES-256-GCM 密钥在 TEE 内生成、**不可导出、不落盘**（只留 keyAlias），
//   密文格式 `huks1:<b64(nonce)>:<b64(密文+tag)>`。这样"整机备份被导出"也解不开 —— 密钥不在备份里。
//   写入前做**自检**：HUKS 密文必须能自解回原文才允许落盘，否则本进程直接回落软件 AES。
// - **回落**：个别设备 HUKS 不可用（初始化/权限异常/加解密不一致）时退回"AES 密钥存偏好"的软件方案
//   （`aes1:` 前缀），宁可安全性降级也不能让"账号存不上"。探测结果在进程内缓存，避免每轮同步重复试错。
//   ⚠️ 清密钥（purgeSoftKey）**必须确认密文已是 `huks1:`**，否则会把仍依赖软件密钥的 `aes1:` 密文解坏。
// - **旧数据迁移**：更早的无前缀软件 AES 密文、旧版明文存储（caldav_account 的 acc_0..n）
//   在首次 loadAll 时读出并就地升级为 HUKS 密文，随后清除偏好中的明文密钥与旧存储。
import { preferences } from '@kit.ArkData';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { huks } from '@kit.UniversalKeystoreKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

export const TYPE_CALDAV: string = 'caldav';
export const TYPE_CARDDAV: string = 'carddav';
export const TYPE_WEBDAV: string = 'webdav';
export const TYPE_KEYS: string[] = [TYPE_CALDAV, TYPE_CARDDAV, TYPE_WEBDAV];

/** 本机事件所属的虚拟日历 key */
export const LOCAL_CAL_KEY: string = 'local';

/** 旧版明文存储（迁移后清除） */
const LEGACY_STORE: string = 'caldav_account';
const LEGACY_COUNT_KEY: string = 'accountCount';

/** 加密存储 */
const VAULT_STORE: string = 'caldav_vault';
/** 旧版"软件 AES 密钥"（明文存偏好）；升级到 HUKS 后会被清除 */
const VAULT_KEY: string = 'key_b64';
const VAULT_DATA: string = 'data_b64';

/** HUKS 密钥别名：固定不变；密钥本体在 TEE 内，应用永远拿不到明文 */
const HUKS_ALIAS: string = 'synccalendar_vault_aes256_gcm';
/** 密文前缀：区分 HUKS 密文 / 软件 AES 密文（无前缀 = 更早的旧格式，按软件 AES 解） */
const PREFIX_HUKS: string = 'huks1:';
const PREFIX_AES: string = 'aes1:';

/**
 * DAV 账号（@Observed 使同步状态变化能刷新列表 UI）
 */
@Observed
export class DavAccount {
  id: string = '';
  type: string = TYPE_CALDAV;
  name: string = '';
  serverUrl: string = '';
  username: string = '';
  password: string = '';
  calendarHrefs: string[] = [];
  calendarNames: string[] = [];
  /** 服务器端定义的日历本颜色（calendar-color），与 calendarHrefs 一一对应，空串表示未定义 */
  calendarColors: string[] = [];
  /** 各日历本写权限（'1'=可写 '0'=只读），与 calendarHrefs 一一对应；空数组表示未知（按可写处理） */
  calendarWritable: string[] = [];
  itemCount: number = 0;
  lastSyncTime: string = '';
}

/** 日历本来源（用于界面显隐与取色） */
export class CalSource {
  calKey: string = '';
  name: string = '';
  color: string = '#007DFF';
  source: string = 'dav'; // 'dav' | 'system' | 'local'
  visible: boolean = true;
  writable: boolean = true; // 只读日历本中的日程只能查看详情，不能编辑
}

/** 与 UI 无关的调色板 */
export class BookPalette {
  static colors: string[] = [
    '#007DFF', '#FF7D00', '#00B96B', '#9F44FF', '#F5317F', '#00B2C6', '#B58600', '#6D4AFF'
  ];
  static colorFor(index: number): string {
    return BookPalette.colors[index % BookPalette.colors.length];
  }

  /**
   * 按日历本的**稳定标识**（集合 href）派生回退色。
   *
   * 为什么不用 colorFor(索引)：服务器未返回颜色时若按索引取色，一旦在服务器上
   * 新增/删除日历本导致列表顺序变化，索引就会位移，**同一个日历本的颜色会跟着变**
   * （表现为"加了个新日历本，其他日历本色块颜色全不对了"）。
   * 用 href 做哈希派生则与顺序无关，增删日历本不会影响其余日历本的颜色。
   */
  static colorForHref(href: string): string {
    let h: number = 0;
    for (let i = 0; i < href.length; i++) {
      h = (h * 31 + href.charCodeAt(i)) >>> 0;
    }
    return BookPalette.colors[h % BookPalette.colors.length];
  }
}

function bytesToB64(u: Uint8Array): string {
  return new util.Base64Helper().encodeToStringSync(u);
}

function b64ToBytes(s: string): Uint8Array {
  return new util.Base64Helper().decodeSync(s);
}

function strToBytes(s: string): Uint8Array {
  return new util.TextEncoder().encodeInto(s);
}

function bytesToStr(u: Uint8Array): string {
  return new util.TextDecoder('utf-8').decodeToString(u);
}

/**
 * 账号加密存储实现。
 *
 * **首选 HUKS（硬件密钥库）**：AES-256-GCM 密钥在 TEE 内生成、**不可导出、不落盘**，
 * 应用侧只持有 keyAlias。因此「整机备份被导出」到其他设备也无法解密（密钥不在备份中、且与设备绑定）。
 *
 * **回落**：HUKS 初始化/调用异常时退回软件 AES（密钥存偏好，`aes1:` 前缀）——
 * 本环境无法真机验证 HUKS，留此安全网可确保"最坏情况 = 与改造前一致"，绝不出现存不上账号。
 * 探测结果缓存在 `huksReady`，避免每轮同步反复试错。
 *
 * 密文自描述（前缀区分算法），便于日后识别与再迁移：
 *   `huks1:<b64(nonce)>:<b64(密文+tag)>` | `aes1:<b64(iv)>:<b64(密文+tag)>` | `<b64(iv)>:<b64(...)>`（更早旧格式）
 */
class Vault {
  /** 软件方案：进程内缓存，避免每轮同步重复读偏好 */
  private static keyB64: string = '';
  /** HUKS 可用性：null=未探测；true=可用；false=已判定不可用（本进程不再重试） */
  private static huksReady: boolean | null = null;

  static async prefs(context: common.Context): Promise<preferences.Preferences> {
    return preferences.getPreferences(context, VAULT_STORE);
  }

  // ==================== HUKS（首选路径） ====================

  /** 生成密钥所用属性（AES-256-GCM，同时具备加密与解密用途） */
  private static genProperties(): huks.HuksParam[] {
    return [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE,
        value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT | huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
      { tag: huks.HuksTag.HUKS_TAG_KEY_ALIAS, value: strToBytes(HUKS_ALIAS) },
      { tag: huks.HuksTag.HUKS_TAG_IS_KEY_ALIAS, value: true }
    ];
  }

  /** 单次加/解密操作属性（NONCE 由调用方追加；GCM 无需 digest/padding 之外参数） */
  private static opProperties(purpose: number): huks.HuksParam[] {
    return [
      { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
      { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
      { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
      { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
      { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE }
    ];
  }

  /**
   * 确保 HUKS 密钥存在（不存在则生成）。返回当前是否可用。
   * 任何异常都视为"HUKS 不可用"并缓存，后续直接走软件回落，不再反复抛错。
   */
  private static async ensureHuksKey(): Promise<boolean> {
    if (Vault.huksReady === false) {
      return false;
    }
    try {
      const exists: boolean = await huks.isKeyItemExist(HUKS_ALIAS, { properties: Vault.genProperties() });
      if (exists) {
        Vault.huksReady = true;
        return true;
      }
      try {
        await huks.generateKeyItem(HUKS_ALIAS, { properties: Vault.genProperties() });
        console.info('[Vault] 已在 HUKS 中生成账号库密钥');
      } catch (genErr) {
        // 生成失败也可能只是"密钥其实已存在"（isKeyItemExist 属性校验差异 / 并发）：
        // 再确认一次，确认存在就视为可用 —— 否则会误判为"不可用"而静默降级成软件加密。
        const ge = genErr as BusinessError;
        const again: boolean = await huks.isKeyItemExist(HUKS_ALIAS, { properties: Vault.genProperties() });
        if (!again) {
          throw new Error(`HUKS 生成密钥失败(code=${ge.code}): ${ge.message}`);
        }
        console.info('[Vault] HUKS 密钥已存在，直接使用');
      }
      Vault.huksReady = true;
      return true;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[Vault] HUKS 不可用(code=${e.code})，本次回落软件加密: ${e.message}`);
      Vault.huksReady = false;
      return false;
    }
  }

  /** GCM 附加认证数据（固定常量）：把密文绑定到"账号库"这一用途，防密文被挪作他用 */
  private static aad(): Uint8Array {
    return strToBytes('synccalendar-vault-v1');
  }

  /**
   * HUKS 加密（initSession → finishSession 一次性完成）。
   * 本 SDK **没有** `huks.encryptItem` 一次性接口，必须走会话式 API。
   * 返回 `b64(nonce):b64(密文+GCM tag)`（不含前缀）——nonce 在加密时显式指定，
   * 故返回数据为「密文 + AEAD(16B)」，nonce 由我们单独保存。
   */
  private static async huksEncrypt(plain: string): Promise<string> {
    const nonce: Uint8Array = cryptoFramework.createRandom().generateRandomSync(12).data;
    const props: huks.HuksParam[] = Vault.opProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT);
    props.push({ tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce });
    props.push({ tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA, value: Vault.aad() });
    const session: huks.HuksSessionHandle = await huks.initSession(HUKS_ALIAS, { properties: props });
    const result: huks.HuksReturnResult =
      await huks.finishSession(session.handle, { properties: props, inData: strToBytes(plain) });
    const buf: Uint8Array | undefined = result.outData;
    if (buf === undefined || buf.length === 0) {
      throw new Error('HUKS 加密返回空数据');
    }
    return `${bytesToB64(nonce)}:${bytesToB64(buf)}`;
  }

  /** HUKS 解密（nonce 与密文分开传递）；失败抛异常由上层统一兜底 */
  private static async huksDecrypt(nonceB64: string, cipherB64: string): Promise<string | null> {
    const props: huks.HuksParam[] = Vault.opProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT);
    props.push({ tag: huks.HuksTag.HUKS_TAG_NONCE, value: b64ToBytes(nonceB64) });
    props.push({ tag: huks.HuksTag.HUKS_TAG_ASSOCIATED_DATA, value: Vault.aad() });
    const session: huks.HuksSessionHandle = await huks.initSession(HUKS_ALIAS, { properties: props });
    const result: huks.HuksReturnResult =
      await huks.finishSession(session.handle, { properties: props, inData: b64ToBytes(cipherB64) });
    const buf: Uint8Array | undefined = result.outData;
    return buf === undefined ? null : bytesToStr(buf);
  }

  /**
   * 清除偏好里的旧"软件 AES 密钥"（密文已升级为 HUKS 后调用）。
   * 目的：不再让可解密的密钥留在偏好（也就不会随备份外泄）。
   */
  static async purgeSoftKey(context: common.Context): Promise<void> {
    try {
      const store: preferences.Preferences = await Vault.prefs(context);
      const had: string = await store.get(VAULT_KEY, '') as string;
      if (had === '') {
        return;
      }
      store.delete(VAULT_KEY);
      await store.flush();
      Vault.keyB64 = '';
      console.info('[Vault] 已清除偏好中的旧 AES 密钥（密文已由 HUKS 保护）');
    } catch (err) {
      // 清理失败不影响功能，下次启动再试
    }
  }

  /**
   * 【逃生舱 · 内部实现】清空账号库：删除偏好中的账号密文与软件密钥，并尽力删除 HUKS 密钥。
   *
   * 用途：账号库**存在但解不开**时（例如密钥丢失、HUKS 密钥失效），`canReadExisting()` 会拒绝
   * 任何写入 —— 用户既看不到账号，也加不了新账号，只能"清除整个应用数据"才能恢复。
   * 本方法提供一条更窄的出路：**只清账号，不动设置与日程**。
   *
   * ⚠️ 仅供 `AccountStore.resetVault()` 在**用户显式二次确认后**调用，**绝不自动触发**
   *    （自动清理会破坏 `canReadExisting` 的防覆盖保护）。
   */
  static async clearVault(context: common.Context): Promise<void> {
    const store: preferences.Preferences = await Vault.prefs(context);
    store.delete(VAULT_DATA);
    store.delete(VAULT_KEY);
    await store.flush();
    Vault.keyB64 = '';
    try {
      await huks.deleteKeyItem(HUKS_ALIAS, { properties: Vault.genProperties() });
      console.info('[Vault] 已删除 HUKS 账号库密钥');
    } catch (err) {
      // 密钥不存在或删除失败都不影响"重置"的目的（密文已删，重新添加时会重新生成）
      const e = err as BusinessError;
      console.error(`[Vault] 删除 HUKS 密钥失败(code=${e.code}): ${e.message}`);
    }
    Vault.huksReady = null; // 让后续重新探测
    console.info('[Vault] 账号库已清空');
  }

  // ==================== 软件 AES（回落路径） ====================

  /**
   * 读取**已存在**的软件 AES 密钥；不存在返回 null。
   *
   * ⚠️ 解密路径必须用这个：早期 `softKey()` 在解密时若发现密钥缺失，会"顺手生成一把新密钥"，
   * 于是旧密文被一把错误的新密钥去解 → 表现为"账号突然全没了，而且再也加不上"。
   */
  private static async softKeyExisting(context: common.Context): Promise<cryptoFramework.SymKey | null> {
    if (Vault.keyB64 === '') {
      const store: preferences.Preferences = await Vault.prefs(context);
      Vault.keyB64 = await store.get(VAULT_KEY, '') as string;
    }
    if (Vault.keyB64 === '') {
      return null;
    }
    return cryptoFramework.createSymKeyGenerator('AES256').convertKey({ data: b64ToBytes(Vault.keyB64) });
  }

  /**
   * 获取（或首次生成）软件 AES-256 密钥；进程内缓存 keyB64。
   * **仅加密路径可调用**（只有加密时才允许"没有就新建一把"）。
   *
   * ⚠️ 仅作为 HUKS 不可用时的回落：此方案下密钥与密文同存 caldav_vault，
   * 对"备份被导出"无防护（`backup_config.json` 已把 preferences 排除出备份以缓解）。
   */
  private static async softKey(context: common.Context): Promise<cryptoFramework.SymKey> {
    const existing: cryptoFramework.SymKey | null = await Vault.softKeyExisting(context);
    if (existing !== null) {
      return existing;
    }
    const gen: cryptoFramework.SymKeyGenerator =
      cryptoFramework.createSymKeyGenerator('AES256');
    const key: cryptoFramework.SymKey = await gen.generateSymKey();
    Vault.keyB64 = bytesToB64(key.getEncoded().data);
    const store: preferences.Preferences = await Vault.prefs(context);
    await store.put(VAULT_KEY, Vault.keyB64);
    await store.flush();
    return key;
  }

  private static gcmParams(iv: Uint8Array, authTag: Uint8Array): cryptoFramework.GcmParamsSpec {
    return {
      algName: 'GcmParamsSpec',
      iv: { data: iv },
      aad: { data: new Uint8Array(0) },
      authTag: { data: authTag }
    };
  }

  /** 软件 AES 加密：返回 `b64(iv):b64(密文+tag)`（不含前缀） */
  private static async softEncrypt(context: common.Context, plain: string): Promise<string> {
    const key: cryptoFramework.SymKey = await Vault.softKey(context);
    const iv: Uint8Array =
      cryptoFramework.createRandom().generateRandomSync(12).data;
    const cipher: cryptoFramework.Cipher =
      cryptoFramework.createCipher('AES256|GCM|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key,
      Vault.gcmParams(iv, new Uint8Array(16)));
    const out: cryptoFramework.DataBlob =
      await cipher.doFinal({ data: strToBytes(plain) });
    return `${bytesToB64(iv)}:${bytesToB64(out.data)}`;
  }

  /** 软件 AES 解密（body = `b64(iv):b64(密文+tag)`）；格式不符返回 null */
  private static async softDecrypt(context: common.Context, body: string): Promise<string | null> {
    const sep: number = body.indexOf(':');
    if (sep <= 0) {
      return null;
    }
    const iv: Uint8Array = b64ToBytes(body.substring(0, sep));
    const blob: Uint8Array = b64ToBytes(body.substring(sep + 1));
    if (blob.length <= 16) {
      return null;
    }
    const tag: Uint8Array = blob.slice(blob.length - 16);
    const ct: Uint8Array = blob.slice(0, blob.length - 16);
    const key: cryptoFramework.SymKey | null = await Vault.softKeyExisting(context);
    if (key === null) {
      console.error('[Vault] 软件 AES 密钥缺失，无法解密（不重新生成，避免把可用密文彻底解坏）');
      return null;
    }
    const cipher: cryptoFramework.Cipher =
      cryptoFramework.createCipher('AES256|GCM|NoPadding');
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, key,
      Vault.gcmParams(iv, tag));
    const out: cryptoFramework.DataBlob = await cipher.doFinal({ data: ct });
    return bytesToStr(out.data);
  }

  // ==================== 对外统一入口 ====================

  /**
   * 加密：优先 HUKS，失败回落软件 AES；返回带前缀的自描述密文。
   *
   * ⚠️ **落盘前自检**：HUKS 写出的密文必须先能自己解回来，才允许以 `huks1:` 写到偏好。
   * 否则某些设备上 HUKS 行为不一致（能加密却解不开），会把"读不回来的密文"写进账号库 ——
   * 下次启动即表现为"账号全部消失且再也加不上"。自检不通过 → 本进程永久回落软件 AES。
   */
  static async encrypt(context: common.Context, plain: string): Promise<string> {
    if (await Vault.ensureHuksKey()) {
      try {
        const body: string = await Vault.huksEncrypt(plain);
        const sep: number = body.indexOf(':');
        const back: string | null =
          await Vault.huksDecrypt(body.substring(0, sep), body.substring(sep + 1));
        if (back === plain) {
          return PREFIX_HUKS + body;
        }
        console.error('[Vault] HUKS 自检失败（加密后解不回原文），本进程回落软件加密');
        Vault.huksReady = false;
      } catch (err) {
        const e = err as BusinessError;
        console.error(`[Vault] HUKS 加密失败(code=${e.code})，回落软件加密: ${e.message}`);
        Vault.huksReady = false;
      }
    }
    return PREFIX_AES + await Vault.softEncrypt(context, plain);
  }

  /**
   * 解密：按前缀分派（`huks1:` / `aes1:` / 无前缀旧格式）。
   * **任何失败都返回 null**（调用方按"无账号 / 迁移路径"处理，绝不静默清空账号）。
   */
  static async decrypt(context: common.Context, stored: string): Promise<string | null> {
    try {
      if (stored.startsWith(PREFIX_HUKS)) {
        const parts: string[] = stored.substring(PREFIX_HUKS.length).split(':');
        if (parts.length !== 2 || !(await Vault.ensureHuksKey())) {
          return null;
        }
        return await Vault.huksDecrypt(parts[0], parts[1]);
      }
      if (stored.startsWith(PREFIX_AES)) {
        return await Vault.softDecrypt(context, stored.substring(PREFIX_AES.length));
      }
      // 更早的旧格式：无前缀软件 AES 密文
      return await Vault.softDecrypt(context, stored);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[Vault] 解密失败: ${e.message}`);
      return null;
    }
  }
}

/**
 * 账号持久化：加密 JSON 存储 + 旧版明文自动迁移
 */
export class AccountStore {
  /** 规范化颜色：#RRGGBBAA → #RRGGBB；非法返回空串 */
  static normalizeColor(raw: string): string {
    const v: string = raw.trim();
    if (/^#[0-9A-Fa-f]{8}$/.test(v)) {
      return '#' + v.substring(3, 9);
    }
    if (/^#[0-9A-Fa-f]{6}$/.test(v)) {
      return v.toUpperCase();
    }
    return '';
  }

  private static decodeAccount(raw: string): DavAccount | null {
    const parts: string[] = raw.split('|');
    if (parts.length < 9) {
      return null;
    }
    const acc = new DavAccount();
    acc.type = parts[0] === '' ? TYPE_CALDAV : parts[0];
    acc.name = parts[1];
    acc.serverUrl = parts[2];
    acc.username = parts[3];
    acc.password = parts[4];
    const count: number = Number(parts[5]);
    acc.itemCount = Number.isNaN(count) ? 0 : count;
    acc.lastSyncTime = parts[6];
    acc.calendarHrefs = parts[7] === '' ? [] : parts[7].split(';');
    acc.calendarNames = parts[8] === '' ? [] : parts[8].split(';');
    if (parts.length >= 10) {
      acc.calendarColors = parts[9] === '' ? [] : parts[9].split(';');
    }
    // 兼容旧版本存储（无 id 字段）：加载时为空，由 loadAll 统一补发并持久化
    if (parts.length >= 11) {
      acc.id = parts[10];
    }
    if (parts.length >= 12) {
      acc.calendarWritable = parts[11] === '' ? [] : parts[11].split(';');
    }
    return acc;
  }

  /** 旧版明文账号编码（迁移旧数据时使用） */
  private static encodeLegacyAccount(acc: DavAccount): string {
    const safe = (s: string): string => s.split('|').join('∥');
    const parts: string[] = [
      safe(acc.type),
      safe(acc.name),
      safe(acc.serverUrl),
      safe(acc.username),
      safe(acc.password),
      String(acc.itemCount),
      safe(acc.lastSyncTime),
      acc.calendarHrefs.join(';'),
      acc.calendarNames.join(';'),
      acc.calendarColors.join(';'),
      safe(acc.id),
      acc.calendarWritable.join(';')
    ];
    return parts.join('|');
  }

  /** 从旧版明文存储读取（无则返回 null） */
  private static async loadLegacy(context: common.Context): Promise<DavAccount[] | null> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, LEGACY_STORE);
      const count: number = await store.get(LEGACY_COUNT_KEY, 0) as number;
      if (count <= 0) {
        return null;
      }
      const result: DavAccount[] = [];
      for (let i = 0; i < count; i++) {
        const raw = await store.get(`acc_${i}`, '') as string;
        if (raw === '') {
          continue;
        }
        const acc = AccountStore.decodeAccount(raw);
        if (acc !== null) {
          if (acc.id === '') {
            acc.id = `acc${Date.now()}_${i}`;
          }
          result.push(acc);
        }
      }
      return result;
    } catch (err) {
      return null;
    }
  }

  /** 清除旧版明文存储（迁移完成后调用） */
  private static async clearLegacy(context: common.Context): Promise<void> {
    try {
      const store: preferences.Preferences =
        await preferences.getPreferences(context, LEGACY_STORE);
      const count: number = await store.get(LEGACY_COUNT_KEY, 0) as number;
      for (let i = 0; i < count; i++) {
        store.delete(`acc_${i}`);
      }
      store.delete(LEGACY_COUNT_KEY);
      await store.flush();
    } catch (err) {
      // 清理失败不影响使用，下次迁移再试
    }
  }

  static async loadAll(context: common.Context): Promise<DavAccount[]> {
    // 1) 新加密存储
    try {
      const store: preferences.Preferences = await Vault.prefs(context);
      const data: string = await store.get(VAULT_DATA, '') as string;
      if (data !== '') {
        const plain: string | null = await Vault.decrypt(context, data);
        if (plain !== null) {
          const arr: Array<Record<string, Object>> =
            JSON.parse(plain) as Array<Record<string, Object>>;
          const result: DavAccount[] = [];
          for (const o of arr) {
            const a = new DavAccount();
            a.id = o['id'] !== undefined ? o['id'] as string : '';
            a.type = o['type'] !== undefined ? o['type'] as string : TYPE_CALDAV;
            a.name = o['name'] !== undefined ? o['name'] as string : '';
            a.serverUrl = o['serverUrl'] !== undefined ? o['serverUrl'] as string : '';
            a.username = o['username'] !== undefined ? o['username'] as string : '';
            a.password = o['password'] !== undefined ? o['password'] as string : '';
            a.calendarHrefs = o['calendarHrefs'] !== undefined ? o['calendarHrefs'] as string[] : [];
            a.calendarNames = o['calendarNames'] !== undefined ? o['calendarNames'] as string[] : [];
            a.calendarColors = o['calendarColors'] !== undefined ? o['calendarColors'] as string[] : [];
            a.calendarWritable = o['calendarWritable'] !== undefined ? o['calendarWritable'] as string[] : [];
            a.itemCount = o['itemCount'] !== undefined ? o['itemCount'] as number : 0;
            a.lastSyncTime = o['lastSyncTime'] !== undefined ? o['lastSyncTime'] as string : '';
            if (a.id === '') {
              a.id = `acc${Date.now()}_${result.length}`;
            }
            result.push(a);
          }
          console.info(`[AccountStore] loadAll: ${result.length} 个账号（加密存储）`);
          // 旧格式密文（软件 AES / 更早的无前缀格式）：HUKS 可用时就地升级为 huks1: 密文，
          // 随后清除偏好里的明文密钥 —— 让已有账号也获得"密钥不落盘"的保护。
          // ⚠️ 清密钥必须**以"回读到的密文确实是 huks1:"为前提**：
          // 若 HUKS 不可用，saveAll 写回的仍然是 aes1: 密文，此时清掉 key_b64
          // 会把刚写的密文连同旧账号一起变成永久解不开（账号凭空消失 + 再也存不上）。
          if (!data.startsWith(PREFIX_HUKS)) {
            try {
              await AccountStore.saveAll(context, result, true);
              const now: string = await store.get(VAULT_DATA, '') as string;
              if (now.startsWith(PREFIX_HUKS)) {
                await Vault.purgeSoftKey(context);
                console.info('[AccountStore] 账号密文已升级为 HUKS 保护');
              } else {
                console.info('[AccountStore] HUKS 不可用，维持软件 AES 加密（保留密钥，不清除）');
              }
            } catch (err) {
              // 升级失败不阻断本次读取，下次启动再试
            }
          }
          return result;
        }
        console.error('[AccountStore] 加密账号数据解密失败');
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[AccountStore] 读取加密账号失败: ${e.message}`);
    }

    // 2) 旧版明文存储 → 迁移
    const legacy: DavAccount[] | null = await AccountStore.loadLegacy(context);
    if (legacy !== null) {
      console.info(`[AccountStore] 迁移 ${legacy.length} 个明文账号到加密存储`);
      await AccountStore.saveAll(context, legacy, true);
      await AccountStore.clearLegacy(context);
      return legacy;
    }
    return [];
  }

  /**
   * 保存全部账号（整体加密写入）。
   * 防御：当前已有账号时，禁止用空列表覆盖（调用方因读取异常拿到空列表再回写，
   * 会把所有账号抹掉）。仅删除账号的合法场景通过 force=true 放行。
   */
  static async saveAll(context: common.Context, accounts: DavAccount[], force: boolean = false): Promise<void> {
    // 防御：先看加密存储里现有数量（空列表覆盖保护）
    let existing: number = -1;
    try {
      const store: preferences.Preferences = await Vault.prefs(context);
      const data: string = await store.get(VAULT_DATA, '') as string;
      if (data !== '') {
        const plain: string | null = await Vault.decrypt(context, data);
        if (plain !== null) {
          existing = (JSON.parse(plain) as Array<Record<string, Object>>).length;
        } else {
          // 有密文但解不开：按"存在数据"处理，宁可拦住空写，也不把账号整体清掉
          existing = 1;
        }
      }
    } catch (err) {
      // 读取失败按"未知"处理，不拦截
      existing = -1;
    }
    if (accounts.length === 0 && existing > 0 && !force) {
      console.error(`[AccountStore] 拒绝用空列表覆盖账号存储（原有 ${existing} 个账号）`);
      throw new Error('账号列表为空，已阻止覆盖存储（保护原有账号数据）');
    }
    const plain: string = JSON.stringify(accounts);
    const enc: string = await Vault.encrypt(context, plain);
    const store: preferences.Preferences = await Vault.prefs(context);
    await store.put(VAULT_DATA, enc);
    await store.flush();
    console.info(`[AccountStore] saveAll: ${accounts.length} 个账号已加密写入`);
  }

  /**
   * 追加一个账号（读全量 → push → 整体加密回写）。
   *
   * 防覆盖保护：回写前先探测"现有存储是否可读"（canReadExisting）。
   * 若存储里有密文却解不开（例如 key_b64 丢失或被重新生成），loadAll 会回落成空数组，
   * 此时 push 一个账号后长度 = 1，会绕过 saveAll 的"空列表覆盖保护"→ 其余账号连同密码全部丢失。
   * 因此遇到该情况直接抛错中止：宁可让用户看到失败提示，也不能静默清空账号。
   */
  static async addAccount(context: common.Context, acc: DavAccount): Promise<void> {
    if (!(await AccountStore.canReadExisting(context))) {
      console.error('[AccountStore] 现有账号存储不可读，已中止 addAccount 以防覆盖');
      throw new Error('读取已有账号失败，为避免覆盖已保存的账号，已中止本次添加');
    }
    const list: DavAccount[] = await AccountStore.loadAll(context);
    list.push(acc);
    await AccountStore.saveAll(context, list);
  }

  /**
   * 【逃生舱】重置账号库：清空本地保存的全部账号、服务器地址与密码。
   *
   * 场景：账号库存在但**解不开**（密钥丢失 / HUKS 密钥失效等），此时 `canReadExisting()`
   * 会拒绝任何写入 —— 表现为"账号消失且再也加不上"，而唯一的原生出路是清除**整个**应用数据
   * （会一并丢掉设置偏好、功能引导标记、本地日程库）。本方法只清账号那一块。
   *
   * ⚠️ **必须由用户在界面上二次确认后调用**；日程数据在 CalDAV 服务器上，重新添加账号
   *    并同步即可恢复，但本地保存的密码会被删除且不可撤销。
   */
  static async resetVault(context: common.Context): Promise<void> {
    await Vault.clearVault(context);
    console.info('[AccountStore] 账号库已重置，可重新添加账号');
  }

  /**
   * 探测"现有账号存储是否可读"，供写前加固使用。
   * - 无密文（全新安装 / 已清空）→ true：可以安全写入
   * - 有密文且能解密 → true
   * - 有密文但解密失败 / 读取异常 → false：**绝不能回写**（否则会整体覆盖、丢失全部账号）
   */
  private static async canReadExisting(context: common.Context): Promise<boolean> {
    try {
      const store: preferences.Preferences = await Vault.prefs(context);
      const data: string = await store.get(VAULT_DATA, '') as string;
      if (data === '') {
        return true;
      }
      return (await Vault.decrypt(context, data)) !== null;
    } catch (err) {
      return false;
    }
  }

  /**
   * ⭐ 账号库是否**确认为空白**（不是"读取失败导致的空"）。
   *
   * 为什么需要它：`loadAll()` 内部把所有异常都 catch 掉并返回 `[]`，
   * 于是调用方无法从返回值区分两种情况：
   *   ① 账号库真的空（全新安装 / 用户重置 / **卸载重装**）；
   *   ② 密文存在但解不开，或读取过程抛错（临时故障）。
   *
   * 系统日历镜像的孤儿清理必须只在 ① 时动手 —— ② 若照常清理，
   * 会把"账号其实还在"的镜像账户全部误删（用户日程从系统日历里消失）。
   *
   * 判定口径（三者同时成立才算"确认空白"）：
   *   - 偏好里**没有**账号密文（`data_b64` 为空）；
   *   - 旧版明文存储也没有账号；
   *   - 读取过程没有抛异常。
   *
   * @returns true = 确认空白，可安全清理孤儿镜像；false = 拿不准，调用方必须保守跳过
   */
  static async isEmptyVaultConfirmed(context: common.Context): Promise<boolean> {
    try {
      const store: preferences.Preferences = await Vault.prefs(context);
      const data: string = await store.get(VAULT_DATA, '') as string;
      if (data !== '') {
        // 有密文：只有能解出"0 个账号"才算确认空白；解不开一律视为拿不准
        const plain: string | null = await Vault.decrypt(context, data);
        if (plain === null) {
          return false;
        }
        const arr: Array<Record<string, Object>> = JSON.parse(plain) as Array<Record<string, Object>>;
        return arr.length === 0;
      }
      // 无密文：再看旧版明文存储是否还有残留账号
      const legacy: DavAccount[] | null = await AccountStore.loadLegacy(context);
      return legacy === null || legacy.length === 0;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[AccountStore] isEmptyVaultConfirmed 判定失败（按"拿不准"处理）: ${e.message}`);
      return false;
    }
  }
}
