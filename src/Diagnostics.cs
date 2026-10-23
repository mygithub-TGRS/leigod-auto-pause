using System;
using System.Globalization;
using System.IO;
using System.Text;

namespace LeigodAutoPause
{
    /// <summary>
    /// 启动期异常的本机留痕。控制台是 GUI 程序，没有控制台窗口可以看堆栈，
    /// 而“界面为什么没起来”必须能事后查；日志只写在本机 app\logs，不外发。
    /// </summary>
    internal static class Diagnostics
    {
        private const long MaximumBytes = 256 * 1024;

        /// <summary>
        /// 记录“为什么写不进去”的本机事实：身份、位数、当前目录，以及在同一目录里
        /// 直接写一个探针文件的结果。判断是路径问题还是进程权限问题时非常有用。
        /// </summary>
        public static void LogProbe(AppPaths paths, string context, string targetPath, Exception exception)
        {
            string directory = "";
            try
            {
                directory = Path.GetDirectoryName(targetPath);
            }
            catch (Exception)
            {
            }

            StringBuilder builder = new StringBuilder();
            builder.AppendLine("  target     : " + targetPath);
            builder.AppendLine("  directory  : " + directory + " exists=" + (Directory.Exists(directory) ? "true" : "false"));
            builder.AppendLine("  identity   : " + System.Security.Principal.WindowsIdentity.GetCurrent().Name);
            builder.AppendLine("  x64        : " + Environment.Is64BitProcess.ToString());
            builder.AppendLine("  cwd        : " + Environment.CurrentDirectory);
            builder.AppendLine("  hresult    : 0x" + exception.HResult.ToString("X8", CultureInfo.InvariantCulture));
            try
            {
                string probePath = Path.Combine(directory ?? "", "lap-probe-" + Guid.NewGuid().ToString("N") + ".txt");
                File.WriteAllText(probePath, "probe");
                File.Delete(probePath);
                builder.AppendLine("  probeWrite : OK");
            }
            catch (Exception probeError)
            {
                builder.AppendLine("  probeWrite : FAIL " + probeError.GetType().Name + " 0x" + probeError.HResult.ToString("X8", CultureInfo.InvariantCulture));
            }

            LogException(paths, context, exception);
            try
            {
                File.AppendAllText(Path.Combine(paths.LogDirectory, "ui-error.log"), builder.ToString() + Environment.NewLine, new UTF8Encoding(false));
            }
            catch (Exception)
            {
            }
        }        public static void LogException(AppPaths paths, string context, Exception exception)
        {
            if (exception == null)
            {
                return;
            }

            try
            {
                Directory.CreateDirectory(paths.LogDirectory);
                string path = Path.Combine(paths.LogDirectory, "ui-error.log");
                if (File.Exists(path) && new FileInfo(path).Length > MaximumBytes)
                {
                    File.Delete(path);
                }

                StringBuilder builder = new StringBuilder();
                builder.Append('[');
                builder.Append(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture));
                builder.Append("] ");
                builder.Append(context);
                builder.AppendLine();
                builder.AppendLine(exception.ToString());
                builder.AppendLine();

                File.AppendAllText(path, builder.ToString(), new UTF8Encoding(false));
            }
            catch (Exception)
            {
                // 诊断失败不能反过来影响启动路径。
            }
        }
    }
}
