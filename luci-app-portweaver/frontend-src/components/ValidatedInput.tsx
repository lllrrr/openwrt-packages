/**
 * 创建带验证的通用 input 元素
 * @param options 配置选项
 * @returns 返回 input 元素
 */
export default function ValidatedInput(options: {
  type?: string;
  className?: string;
  value?: string;
  placeholder?: string;
  style?: string;
  disabled?: boolean;
  onValidate?: (value: string) => boolean;
  dataAttributes?: Record<string, string>;
  validateOn?: "input" | "blur" | "change" | "both";
}) {
  const {
    type = "text",
    className = "",
    value = "",
    placeholder = "",
    style = "",
    disabled = false,
    onValidate,
    dataAttributes = {},
    validateOn = "both",
  } = options;

  const dataAttrs: Record<string, string> = {};
  Object.entries(dataAttributes).forEach(([key, val]) => {
    dataAttrs[`data-${key}`] = val;
  });

  const input = (
    <input
      type={type}
      class={className}
      value={value}
      placeholder={placeholder}
      style={style}
      disabled={disabled}
      {...dataAttrs}
    />
  ) as HTMLInputElement;

  const validate = () => {
    if (onValidate) {
      const isValid = onValidate(input.value.trim());
      if (!isValid) {
        input.style.setProperty("border-color", "red", "important");
      } else {
        input.style.borderColor = "";
      }
    }
  };

  const clearValidation = () => {
    input.style.borderColor = "";
  };

  if (validateOn === "input") {
    input.addEventListener("input", validate);
  } else if (validateOn === "blur") {
    input.addEventListener("input", clearValidation);
    input.addEventListener("blur", validate);
  } else if (validateOn === "change") {
    input.addEventListener("change", validate);
  } else if (validateOn === "both") {
    input.addEventListener("input", validate);
    input.addEventListener("change", validate);
  }

  return input;
}
