using System;
using System.Threading;

namespace LeigodAutoPause
{
    /// <summary>
    /// 通过命名互斥量的可获取性判断后台监控是否在运行：
    /// 拿得到说明没有进程持有它（已停止），拿不到说明监控正在运行。
    /// 与 PowerShell 版 Get-MonitorInstanceState 一致，不需要读取进程命令行。
    /// </summary>
    internal sealed class MutexHolder
    {
        private MutexHolder(string state)
        {
            State = state;
        }

        public string State { get; private set; }

        public static MutexHolder Probe(string mutexName)
        {
            Mutex mutex = null;
            bool acquired = false;
            try
            {
                mutex = new Mutex(false, mutexName);
                try
                {
                    acquired = mutex.WaitOne(0, false);
                }
                catch (AbandonedMutexException)
                {
                    acquired = true;
                }

                return new MutexHolder(acquired ? "Stopped" : "Running");
            }
            catch (UnauthorizedAccessException)
            {
                return new MutexHolder("Unknown");
            }
            catch (Exception)
            {
                return new MutexHolder("Unknown");
            }
            finally
            {
                if (mutex != null)
                {
                    if (acquired)
                    {
                        try
                        {
                            mutex.ReleaseMutex();
                        }
                        catch (Exception)
                        {
                        }
                    }
                    mutex.Dispose();
                }
            }
        }
    }
}
