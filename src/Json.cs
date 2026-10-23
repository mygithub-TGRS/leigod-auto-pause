using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text;

namespace LeigodAutoPause
{
    /// <summary>
    /// 保持键顺序的对象容器。配置读写依赖它：界面上点一次“保存”后，
    /// 用户手写的键、未来新增的键都必须原样留在文件里，顺序也尽量稳定。
    /// </summary>
    internal sealed class JsonObject
    {
        private readonly List<string> _keys = new List<string>();
        private readonly Dictionary<string, object> _values = new Dictionary<string, object>(StringComparer.Ordinal);

        public IList<string> Keys
        {
            get { return _keys; }
        }

        public object Get(string key)
        {
            object value;
            if (_values.TryGetValue(key, out value))
            {
                return value;
            }
            return null;
        }

        public bool Has(string key)
        {
            return _values.ContainsKey(key);
        }

        public void Set(string key, object value)
        {
            if (!_values.ContainsKey(key))
            {
                _keys.Add(key);
            }
            _values[key] = value;
        }
    }

    /// <summary>
    /// 只服务于本项目的迷你 JSON 实现。
    /// 不引用 System.Web.Extensions 是因为 JavaScriptSerializer 会把形如日期的字符串
    /// 自动转成 DateTime，而 runtime-state.json 的 updated_at / pause_deadline_at
    /// 必须按原始字符串解析；手写一份可以保证类型不被悄悄改写。
    /// </summary>
    internal static class Json
    {
        public static object Parse(string text)
        {
            if (text == null)
            {
                throw new FormatException("JSON 内容为空。");
            }
            Parser parser = new Parser(text);
            object value = parser.ParseValue();
            parser.SkipTrivia();
            if (!parser.AtEnd)
            {
                throw new FormatException("JSON 末尾存在多余内容。");
            }
            return value;
        }

        public static string Serialize(object value, bool indented)
        {
            StringBuilder builder = new StringBuilder(1024);
            WriteValue(builder, value, indented, 0);
            return builder.ToString();
        }

        // ---- 取值辅助：缺失、类型不符或为 null 时一律回退到调用方给的默认值，
        //      和 PowerShell 的 Get-ConfigValue 语义保持一致。 ----

        public static string String(object value, string defaultValue)
        {
            if (value == null)
            {
                return defaultValue;
            }
            string text = value as string;
            if (text != null)
            {
                return text;
            }
            if (value is bool)
            {
                return ((bool)value) ? "True" : "False";
            }
            if (value is long || value is double)
            {
                return Json.NumberToText(value);
            }
            return defaultValue;
        }

        public static bool Bool(object value, bool defaultValue)
        {
            if (value == null)
            {
                return defaultValue;
            }
            if (value is bool)
            {
                return (bool)value;
            }
            string text = value as string;
            if (text != null)
            {
                bool parsed;
                if (bool.TryParse(text, out parsed))
                {
                    return parsed;
                }
            }
            return defaultValue;
        }

        public static int Int(object value, int defaultValue)
        {
            if (value == null)
            {
                return defaultValue;
            }
            if (value is long)
            {
                return (int)(long)value;
            }
            if (value is double)
            {
                return (int)(double)value;
            }
            string text = value as string;
            if (text != null)
            {
                int parsed;
                if (int.TryParse(text.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed))
                {
                    return parsed;
                }
            }
            return defaultValue;
        }

        public static string[] StringArray(object value)
        {
            List<string> items = new List<string>();
            IList<object> list = value as IList<object>;
            if (list != null)
            {
                for (int index = 0; index < list.Count; index++)
                {
                    string item = list[index] as string;
                    if (!string.IsNullOrEmpty(item))
                    {
                        items.Add(item);
                    }
                }
            }
            return items.ToArray();
        }

        public static string ToDisplayString(object value)
        {
            if (value == null)
            {
                return "";
            }
            string text = value as string;
            if (text != null)
            {
                return text;
            }
            if (value is bool)
            {
                return ((bool)value) ? "True" : "False";
            }
            if (value is long || value is double)
            {
                return NumberToText(value);
            }
            return "";
        }

        private static string NumberToText(object value)
        {
            if (value is long)
            {
                return ((long)value).ToString(CultureInfo.InvariantCulture);
            }
            if (value is double)
            {
                double number = (double)value;
                if (Math.Abs(number - Math.Round(number)) < double.Epsilon && Math.Abs(number) < 1e15)
                {
                    return ((long)Math.Round(number)).ToString(CultureInfo.InvariantCulture);
                }
                return number.ToString("R", CultureInfo.InvariantCulture);
            }
            return "";
        }

        private static void WriteValue(StringBuilder builder, object value, bool indented, int depth)
        {
            if (value == null)
            {
                builder.Append("null");
                return;
            }

            string text = value as string;
            if (text != null)
            {
                WriteString(builder, text);
                return;
            }

            if (value is bool)
            {
                builder.Append(((bool)value) ? "true" : "false");
                return;
            }

            if (value is long || value is int)
            {
                builder.Append(Convert.ToInt64(value, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture));
                return;
            }

            if (value is double || value is float || value is decimal)
            {
                double number = Convert.ToDouble(value, CultureInfo.InvariantCulture);
                if (double.IsNaN(number) || double.IsInfinity(number))
                {
                    builder.Append("null");
                    return;
                }
                if (Math.Abs(number - Math.Round(number)) < double.Epsilon && Math.Abs(number) < 1e15)
                {
                    builder.Append(((long)Math.Round(number)).ToString(CultureInfo.InvariantCulture));
                    return;
                }
                builder.Append(number.ToString("R", CultureInfo.InvariantCulture));
                return;
            }

            JsonObject jsonObject = value as JsonObject;
            if (jsonObject != null)
            {
                WriteObject(builder, jsonObject, indented, depth);
                return;
            }

            IList<object> list = value as IList<object>;
            if (list != null)
            {
                WriteArray(builder, list, indented, depth);
                return;
            }

            string[] strings = value as string[];
            if (strings != null)
            {
                List<object> items = new List<object>();
                for (int index = 0; index < strings.Length; index++)
                {
                    items.Add(strings[index]);
                }
                WriteArray(builder, items, indented, depth);
                return;
            }

            WriteString(builder, Convert.ToString(value, CultureInfo.InvariantCulture) ?? "");
        }

        private static void WriteObject(StringBuilder builder, JsonObject value, bool indented, int depth)
        {
            if (value.Keys.Count == 0)
            {
                builder.Append("{}");
                return;
            }

            builder.Append('{');
            for (int index = 0; index < value.Keys.Count; index++)
            {
                if (index > 0)
                {
                    builder.Append(',');
                }
                if (indented)
                {
                    builder.AppendLine();
                    builder.Append(' ', (depth + 1) * 4);
                }
                WriteString(builder, value.Keys[index]);
                builder.Append(indented ? ": " : ":");
                WriteValue(builder, value.Get(value.Keys[index]), indented, depth + 1);
            }
            if (indented)
            {
                builder.AppendLine();
                builder.Append(' ', depth * 4);
            }
            builder.Append('}');
        }

        private static void WriteArray(StringBuilder builder, IList<object> value, bool indented, int depth)
        {
            if (value.Count == 0)
            {
                builder.Append("[]");
                return;
            }

            builder.Append('[');
            for (int index = 0; index < value.Count; index++)
            {
                if (index > 0)
                {
                    builder.Append(',');
                }
                if (indented)
                {
                    builder.AppendLine();
                    builder.Append(' ', (depth + 1) * 4);
                }
                WriteValue(builder, value[index], indented, depth + 1);
            }
            if (indented)
            {
                builder.AppendLine();
                builder.Append(' ', depth * 4);
            }
            builder.Append(']');
        }

        private static void WriteString(StringBuilder builder, string value)
        {
            builder.Append('"');
            for (int index = 0; index < value.Length; index++)
            {
                char character = value[index];
                switch (character)
                {
                    case '"':
                        builder.Append("\\\"");
                        break;
                    case '\\':
                        builder.Append("\\\\");
                        break;
                    case '\b':
                        builder.Append("\\b");
                        break;
                    case '\f':
                        builder.Append("\\f");
                        break;
                    case '\n':
                        builder.Append("\\n");
                        break;
                    case '\r':
                        builder.Append("\\r");
                        break;
                    case '\t':
                        builder.Append("\\t");
                        break;
                    default:
                        if (character < ' ')
                        {
                            builder.Append("\\u");
                            builder.Append(((int)character).ToString("x4", CultureInfo.InvariantCulture));
                        }
                        else
                        {
                            builder.Append(character);
                        }
                        break;
                }
            }
            builder.Append('"');
        }

        private sealed class Parser
        {
            private readonly string _text;
            private int _index;

            public Parser(string text)
            {
                _text = text;
                _index = 0;
                if (_text.Length > 0 && _text[0] == '\uFEFF')
                {
                    _index = 1;
                }
            }

            public bool AtEnd
            {
                get { return _index >= _text.Length; }
            }

            public void SkipTrivia()
            {
                while (_index < _text.Length)
                {
                    char character = _text[_index];
                    if (character == ' ' || character == '\t' || character == '\r' || character == '\n')
                    {
                        _index++;
                        continue;
                    }
                    break;
                }
            }

            public object ParseValue()
            {
                SkipTrivia();
                if (AtEnd)
                {
                    throw new FormatException("JSON 在预期值的位置提前结束。");
                }

                char character = _text[_index];
                switch (character)
                {
                    case '{':
                        return ParseObject();
                    case '[':
                        return ParseArray();
                    case '"':
                        return ParseString();
                    case 't':
                        Expect("true");
                        return true;
                    case 'f':
                        Expect("false");
                        return false;
                    case 'n':
                        Expect("null");
                        return null;
                    default:
                        if (character == '-' || (character >= '0' && character <= '9'))
                        {
                            return ParseNumber();
                        }
                        throw new FormatException("JSON 中出现了无法识别的字符: " + character);
                }
            }

            private JsonObject ParseObject()
            {
                JsonObject result = new JsonObject();
                _index++; // '{'
                SkipTrivia();
                if (!AtEnd && _text[_index] == '}')
                {
                    _index++;
                    return result;
                }
                while (true)
                {
                    SkipTrivia();
                    string key = ParseString();
                    SkipTrivia();
                    if (AtEnd || _text[_index] != ':')
                    {
                        throw new FormatException("JSON 对象缺少冒号。");
                    }
                    _index++;
                    object value = ParseValue();
                    result.Set(key, value);
                    SkipTrivia();
                    if (AtEnd)
                    {
                        throw new FormatException("JSON 对象缺少右花括号。");
                    }
                    if (_text[_index] == ',')
                    {
                        _index++;
                        continue;
                    }
                    if (_text[_index] == '}')
                    {
                        _index++;
                        return result;
                    }
                    throw new FormatException("JSON 对象分隔符不正确。");
                }
            }

            private List<object> ParseArray()
            {
                List<object> result = new List<object>();
                _index++; // '['
                SkipTrivia();
                if (!AtEnd && _text[_index] == ']')
                {
                    _index++;
                    return result;
                }
                while (true)
                {
                    result.Add(ParseValue());
                    SkipTrivia();
                    if (AtEnd)
                    {
                        throw new FormatException("JSON 数组缺少右方括号。");
                    }
                    if (_text[_index] == ',')
                    {
                        _index++;
                        continue;
                    }
                    if (_text[_index] == ']')
                    {
                        _index++;
                        return result;
                    }
                    throw new FormatException("JSON 数组分隔符不正确。");
                }
            }

            private string ParseString()
            {
                if (AtEnd || _text[_index] != '"')
                {
                    throw new FormatException("JSON 字符串缺少起始引号。");
                }
                _index++;
                StringBuilder builder = new StringBuilder();
                while (true)
                {
                    if (AtEnd)
                    {
                        throw new FormatException("JSON 字符串缺少结束引号。");
                    }
                    char character = _text[_index++];
                    if (character == '"')
                    {
                        return builder.ToString();
                    }
                    if (character != '\\')
                    {
                        builder.Append(character);
                        continue;
                    }
                    if (AtEnd)
                    {
                        throw new FormatException("JSON 字符串转义不完整。");
                    }
                    char escape = _text[_index++];
                    switch (escape)
                    {
                        case '"':
                            builder.Append('"');
                            break;
                        case '\\':
                            builder.Append('\\');
                            break;
                        case '/':
                            builder.Append('/');
                            break;
                        case 'b':
                            builder.Append('\b');
                            break;
                        case 'f':
                            builder.Append('\f');
                            break;
                        case 'n':
                            builder.Append('\n');
                            break;
                        case 'r':
                            builder.Append('\r');
                            break;
                        case 't':
                            builder.Append('\t');
                            break;
                        case 'u':
                            if (_index + 4 > _text.Length)
                            {
                                throw new FormatException("JSON Unicode 转义不完整。");
                            }
                            string hex = _text.Substring(_index, 4);
                            _index += 4;
                            int code;
                            if (!int.TryParse(hex, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out code))
                            {
                                throw new FormatException("JSON Unicode 转义非法。");
                            }
                            builder.Append((char)code);
                            break;
                        default:
                            throw new FormatException("JSON 字符串转义非法: \\" + escape);
                    }
                }
            }

            private object ParseNumber()
            {
                int start = _index;
                if (!AtEnd && _text[_index] == '-')
                {
                    _index++;
                }
                bool isIntegral = true;
                while (!AtEnd)
                {
                    char character = _text[_index];
                    if (character >= '0' && character <= '9')
                    {
                        _index++;
                        continue;
                    }
                    if (character == '.' || character == 'e' || character == 'E' || character == '+' || character == '-')
                    {
                        isIntegral = false;
                        _index++;
                        continue;
                    }
                    break;
                }

                string raw = _text.Substring(start, _index - start);
                if (isIntegral)
                {
                    long integral;
                    if (long.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out integral))
                    {
                        return integral;
                    }
                }
                double number;
                if (!double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out number))
                {
                    throw new FormatException("JSON 数字格式非法: " + raw);
                }
                return number;
            }

            private void Expect(string literal)
            {
                if (_index + literal.Length > _text.Length ||
                    string.CompareOrdinal(_text, _index, literal, 0, literal.Length) != 0)
                {
                    throw new FormatException("JSON 中预期: " + literal);
                }
                _index += literal.Length;
            }
        }
    }
}
