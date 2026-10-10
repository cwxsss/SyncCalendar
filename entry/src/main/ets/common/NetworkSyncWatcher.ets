// entry/src/main/ets/common/NetworkSyncWatcher.ets
// ⭐ 网络恢复补同步：从"无网"变为"有网"时立刻同步一次。
//
// 为什么这条最有价值（《定时同步方案调研.md》第 ④ 层）：
//   延迟任务最短 2 小时、还会随应用活跃度降级，长时间在外(飞行模式/地铁/弱网)期间
//   基本不会跑。用户一旦回到有网环境，**立刻对齐一次**，才能做到
//   "我要看的时候数据是最新的"。这比追求"进程常驻"实际得多。
//
// 实现：net.connection 的 netAvailable / netLost 事件 + 去抖，避免网络抖动时连打多次。
import { connection } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { BackgroundSyncRunner } from './BackgroundSyncRunner';
import { LogUtil } from './LogUtil';

/** 网络恢复后的去抖间隔：避免弱网下反复"断开→恢复"导致连续同步 */
const DEBOUNCE_MS: number = 20 * 1000;

export class NetworkSyncWatcher {
  private static netConn: connection.NetConnection | null = null;
  /** 上一次触发同步的时间，用于去抖 */
  private static lastTriggerAt: number = 0;
  /** 当前是否处于"无网"状态（只有从无网恢复才触发，避免频繁切换网络时误触发） */
  private static offline: boolean = false;

  /** 开始监听网络变化（幂等：重复调用不会重复注册） */
  static start(context: common.UIAbilityContext): void {
    if (NetworkSyncWatcher.netConn !== null) {
      return;
    }
    try {
      const conn: connection.NetConnection = connection.createNetConnection();
      conn.on('netLost', (): void => {
        NetworkSyncWatcher.offline = true;
        LogUtil.write('网络断开：标记为无网状态');
      });
      conn.on('netAvailable', (): void => {
        // ⭐ 只有"从无网恢复"才补同步：单纯切换 Wi-Fi/蜂窝时不重复触发
        if (!NetworkSyncWatcher.offline) {
          return;
        }
        NetworkSyncWatcher.offline = false;
        NetworkSyncWatcher.triggerDebounced(context, 'netRecover');
      });
      conn.register((): void => {
        LogUtil.write('网络监听已注册（网络恢复补同步）');
      });
      NetworkSyncWatcher.netConn = conn;
    } catch (err) {
      LogUtil.write(`网络监听注册失败：${(err as Error).message}`);
    }
  }

  /** 停止监听（一般不需要，App 存活期间持续有效） */
  static stop(): void {
    if (NetworkSyncWatcher.netConn === null) {
      return;
    }
    try {
      NetworkSyncWatcher.netConn.unregister((err: object): void => {
        // 忽略取消失败
      });
    } catch (err) {
      // 忽略
    }
    NetworkSyncWatcher.netConn = null;
  }

  /** 去抖后触发一次同步 */
  private static triggerDebounced(context: common.UIAbilityContext, tag: string): void {
    const now: number = Date.now();
    if (now - NetworkSyncWatcher.lastTriggerAt < DEBOUNCE_MS) {
      LogUtil.write(`网络恢复补同步：距上次过快（<20s），跳过`);
      return;
    }
    NetworkSyncWatcher.lastTriggerAt = now;
    LogUtil.write('网络已恢复 → 触发补同步');
    // 不 await：事件回调里不能阻塞；BackgroundSyncRunner 内部全 try-catch，不会抛出
    BackgroundSyncRunner.runOnce(context, tag);
  }
}