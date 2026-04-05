import { createFrpNodeSelector } from "./FrpNodeSelector";
import ValidatedInput from "./ValidatedInput";
class PortMappingEditor extends L.form.Value {
  private hiddenInput?: HTMLInputElement;
  private errorDivRefs: HTMLElement[] = [];

  parseMapping(str: string) {
    if (!str || typeof str !== "string") return null;
    str = str.trim();
    const mapping = {
      listenPort: "",
      targetPort: "",
      frpNodes: [],
      protocol: "tcp",
    } as {
      listenPort: string;
      targetPort: string;
      frpNodes: string[];
      protocol: "tcp" | "udp" | "both";
    };
    const protocolMatch = str.match(/\/([a-z]+)$/);
    if (protocolMatch) {
      mapping.protocol = protocolMatch[1].toLowerCase() as any;
      str = str.substring(0, protocolMatch.index);
    }
    let i = 0;
    while (str[i] === "[") {
      const end = str.indexOf("]", i);
      if (end === -1) break;
      const content = str.substring(i + 1, end);
      if (content.indexOf(":") !== -1 || /[a-zA-Z_-]/.test(content)) {
        (mapping.frpNodes as string[]).push(content);
        i = end + 1;
        continue;
      }
      if (content.match(/^\d+(?:-\d+)?$/)) {
        mapping.listenPort = content;
        i = end + 1;
        break;
      }
      break;
    }
    const rest = str.substring(i);
    if (!mapping.listenPort) {
      const parts0 = rest.split(":");
      if (parts0.length >= 1)
        mapping.listenPort = parts0[0].trim().replace(/[[\]]/g, "");
      if (parts0.length >= 2)
        mapping.targetPort = parts0[1].trim().replace(/[[\]]/g, "");
    } else {
      if (rest.startsWith(":")) {
        mapping.targetPort = rest.substring(1).trim().replace(/[[\]]/g, "");
      }
    }
    return mapping;
  }
  buildString(mapping: {
    listenPort: string;
    targetPort: string;
    frpNodes: string[];
    protocol: string;
  }) {
    let result = "";
    if (mapping.frpNodes && mapping.frpNodes.length > 0) {
      mapping.frpNodes.forEach((node) => {
        result += `[${node}]`;
      });
    }
    if (mapping.listenPort) {
      if (mapping.frpNodes && mapping.frpNodes.length > 0)
        result += `[${mapping.listenPort}]`;
      else result += mapping.listenPort;
    }
    if (mapping.targetPort) result += `:${mapping.targetPort}`;
    if (mapping.protocol) result += `/${mapping.protocol}`;
    return result;
  }
  renderWidget(
    section_id: string,
    _option_index: number,
    cfgvalue: string[] | string,
  ) {
    void _option_index;

    this.errorDivRefs = [];

    const current_values: string[] = Array.isArray(cfgvalue)
      ? (cfgvalue as string[])
      : typeof cfgvalue === "string"
        ? String(cfgvalue).split(/\s+/).filter(Boolean)
        : [];

    const widget_id = this.cbid(section_id);
    const mappings_wrapper = (<div></div>) as HTMLElement;

    // 存储每个行的元素引用
    const rowRefs: Array<{
      listenInput: HTMLInputElement;
      targetInput: HTMLInputElement;
      protocolSelect: HTMLSelectElement;
      getSelectedNodes: () => string[];
    }> = [];

    const updateHiddenValue = (): void => {
      const values: string[] = [];
      for (const ref of rowRefs) {
        const listen = ref.listenInput.value.trim();
        const target = ref.targetInput.value.trim();
        const protocol = ref.protocolSelect.value;
        const frpNodes = ref.getSelectedNodes();

        const temp = {
          listenPort: listen,
          targetPort: target,
          frpNodes: frpNodes,
          protocol: protocol,
        };
        const str = this.buildString(temp);
        if (str && listen && target) values.push(str);
      }

      if (this.hiddenInput) this.hiddenInput.value = values.join(" ");
    };

    const renderMappingRow = (
      mapping_str: string,
      index: number,
    ): {
      element: HTMLElement;
      listenInput: HTMLInputElement;
      targetInput: HTMLInputElement;
      protocolSelect: HTMLSelectElement;
      getSelectedNodes: () => string[];
    } => {
      const mapping = this.parseMapping(mapping_str) || {
        listenPort: "",
        targetPort: "",
        frpNodes: [],
        protocol: "tcp",
      };
      const initialTextModeValue = mapping_str ? this.buildString(mapping) : "";
      const row_id = `portmapping-row-${section_id}-${index}`;
      let isTextMode = true;

      const listenInput = (
        <ValidatedInput
          type="text"
          className="listen-port-input"
          value={mapping.listenPort}
          placeholder={_("8080 or 8080-8090")}
          style="width: 70px; min-width: 50px; margin-right: 10px;"
          dataAttributes={{ index: String(index), section: section_id }}
          onValidate={(value) => {
            if (!value.trim()) return false;
            return this.validatePortOrRange(value.trim());
          }}
        />
      ) as HTMLInputElement;

      const targetInput = (
        <ValidatedInput
          type="text"
          className="target-port-input"
          value={mapping.targetPort}
          placeholder={_("80 or 80-90")}
          style="width: 70px; min-width: 50px; margin-right: 10px;"
          dataAttributes={{ index: String(index), section: section_id }}
          onValidate={(value) => {
            if (!value.trim()) return false;
            return this.validatePortOrRange(value.trim());
          }}
        />
      ) as HTMLInputElement;

      const protocolSelect = (
        <select
          class="protocol-select"
          data-index={index}
          data-section={section_id}
          style="width: 100px; margin-right: 10px;"
        >
          <option value="tcp" selected={mapping.protocol === "tcp"}>
            TCP
          </option>
          <option value="udp" selected={mapping.protocol === "udp"}>
            UDP
          </option>
          <option value="both" selected={mapping.protocol === "both"}>
            Both
          </option>
        </select>
      ) as HTMLSelectElement;

      const textModeInput = (
        <ValidatedInput
          type="text"
          className="text-mode-input"
          value={initialTextModeValue}
          placeholder={_("[8080][node1:9888]:80/tcp or 8080:80/tcp")}
          style="width: 100%; margin-bottom: 6px; padding: 5px; display: none;"
          validateOn="blur"
          onValidate={(value) => {
            const parsed = this.parseMapping(value);
            return !!parsed;
          }}
        />
      ) as HTMLInputElement;

      const previewDiv = (
        <div
          class="portmapping-preview"
          data-index={index}
          style="margin-top: 6px; padding: 6px; border-left: 3px solid #0088cc; font-family: monospace; font-size: 12px;"
        >
          {_("Preview: %s").format(this.buildString(mapping))}
        </div>
      ) as HTMLElement;

      const updatePreview = (): void => {
        const listen = listenInput.value.trim();
        const target = targetInput.value.trim();
        const protocol = protocolSelect.value;
        const frpNodes = getSelectedNodes();
        const temp_mapping = {
          listenPort: listen,
          targetPort: target,
          frpNodes: frpNodes,
          protocol: protocol,
        };
        const preview_str = this.buildString(temp_mapping);
        previewDiv.textContent = _("Preview: %s").format(preview_str);
        if (!isTextMode) {
          textModeInput.value = preview_str;
        }
      };

      // 使用动态的 FRP 节点选择器组件来保证与文本模式的数据同步
      let selectorContainer: HTMLElement = null as any;
      let getSelectedNodes: () => string[] = null as any;
      let isFrpValid: () => boolean = null as any;
      let getFrpError: () => string = null as any;

      const initOrUpdateFrp = (nodes: string[]) => {
        const selector = createFrpNodeSelector({
          selectedNodes: nodes,
          onChange: () => {
            validateAndUpdate();
          },
          checkboxClass: "frp-node-checkbox-pm",
          portInputClass: "frp-node-port-pm",
        });

        selectorContainer?.parentNode?.replaceChild(
          selector.container,
          selectorContainer,
        );

        selectorContainer = selector.container;
        getSelectedNodes = selector.getSelectedNodes;
        isFrpValid = selector.isValid;
        getFrpError = selector.getValidationError;
      };

      initOrUpdateFrp(mapping.frpNodes || []);

      const frpContainer = (
        <div class="frp-nodes-select" style="display: block; margin-top: 6px;">
          <span style="display: block; margin-bottom: 6px; font-weight: bold;">
            {_("FRP Nodes (Optional):")}
          </span>
        </div>
      ) as HTMLElement;

      frpContainer.appendChild(selectorContainer);

      const errorDiv = (
        <div
          class="portmapping-error"
          data-index={index}
          style="color: red; margin-top: 6px; font-size: 12px; display: none;"
        ></div>
      ) as HTMLElement;

      this.errorDivRefs.push(errorDiv);

      const titleRow = (
        <div style="display: flex; gap: 10px; align-items: center;">
          <span style="min-width: 80px; font-weight: bold;">
            {_("Listen Port:")}
          </span>
          {listenInput}
          <span style="min-width: 80px; font-weight: bold;">
            {_("Target Port:")}
          </span>
          {targetInput}
          <span style="min-width: 60px; font-weight: bold;">
            {_("Protocol:")}
          </span>
          {protocolSelect}
        </div>
      ) as HTMLElement;

      const modeToggleBtn = (
        <button
          type="button"
          class="btn cbi-button cbi-button-edit"
          style="margin-right: 8px;"
        >
          {_("Text Edit")}
        </button>
      );

      const deleteBtn = (
        <button
          type="button"
          class="btn cbi-button cbi-button-remove"
          data-index={index}
          data-section={section_id}
        >
          {_("Delete")}
        </button>
      );

      const buttonRow = (
        <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px;">
          <div>{modeToggleBtn}</div>
          <div>{deleteBtn}</div>
        </div>
      ) as HTMLElement;

      const row = (
        <div
          id={row_id}
          class="portmapping-row"
          data-index={index}
          style="margin-bottom: 10px; padding: 8px; border: 1px solid #ddd; border-radius: 4px;"
        >
          {buttonRow}
          {titleRow}
          {textModeInput}
          {frpContainer}
          {errorDiv}
          {previewDiv}
        </div>
      ) as HTMLElement;

      const validateAndUpdate = (): void => {
        const listen = listenInput.value.trim();
        const target = targetInput.value.trim();

        errorDiv.textContent = "";
        errorDiv.style.display = "none";

        let hasError = false;

        if (listen && !this.validatePortOrRange(listen)) {
          errorDiv.textContent = _("Invalid listen port format");
          errorDiv.style.display = "block";
          hasError = true;
        }

        if (!hasError && target && !this.validatePortOrRange(target)) {
          errorDiv.textContent = _("Invalid target port format");
          errorDiv.style.display = "block";
          hasError = true;
        }

        if (!hasError && listen && target) {
          const listenPorts = this.parsePortRange(listen);
          const targetPorts = this.parsePortRange(target);

          if (listenPorts.length !== targetPorts.length) {
            errorDiv.textContent = _("Port ranges must have the same size");
            errorDiv.style.display = "block";
            hasError = true;
          }
        }

        if (!hasError && !isFrpValid()) {
          errorDiv.textContent = getFrpError();
          errorDiv.style.display = "block";
          hasError = true;
        }

        if (!hasError) {
          updatePreview();
        }

        updateHiddenValue();
      };

      listenInput.oninput = validateAndUpdate;
      listenInput.onchange = validateAndUpdate;
      targetInput.oninput = validateAndUpdate;
      targetInput.onchange = validateAndUpdate;
      protocolSelect.onchange = validateAndUpdate;

      const syncFromTextMode = () => {
        const parsed = this.parseMapping(textModeInput.value);
        if (parsed) {
          const tempListenHandler = listenInput.oninput;
          const tempTargetHandler = targetInput.oninput;
          const tempProtocolHandler = protocolSelect.onchange;

          listenInput.oninput = null;
          targetInput.oninput = null;
          protocolSelect.onchange = null;

          listenInput.value = parsed.listenPort;
          targetInput.value = parsed.targetPort;
          protocolSelect.value = parsed.protocol as any;

          initOrUpdateFrp(parsed.frpNodes || []);

          listenInput.oninput = tempListenHandler;
          targetInput.oninput = tempTargetHandler;
          protocolSelect.onchange = tempProtocolHandler;

          validateAndUpdate();
        }
      };

      textModeInput.oninput = syncFromTextMode;
      textModeInput.onblur = (ev: Event) => {
        const inputEl = ev.currentTarget as HTMLInputElement | null;
        if (!inputEl) return;

        errorDiv.textContent = "";
        errorDiv.style.display = "none";

        const parsed = this.parseMapping(inputEl.value);
        if (parsed) {
          const unifiedStr = this.buildString(parsed);
          if (unifiedStr && unifiedStr !== inputEl.value) {
            inputEl.value = unifiedStr;
          }
          syncFromTextMode();
        } else {
          errorDiv.textContent = _("Invalid port mapping format");
          errorDiv.style.display = "block";
        }
      };
      function setDisplay(element: HTMLElement, display: string) {
        element.style.setProperty("display", display, "important");
      }
      function updateVis() {
        setDisplay(titleRow, isTextMode ? "none" : "flex");
        setDisplay(frpContainer, isTextMode ? "none" : "block");
        setDisplay(textModeInput, isTextMode ? "block" : "none");
        setDisplay(previewDiv, isTextMode ? "none" : "block");
        modeToggleBtn.textContent = isTextMode
          ? _("Visual Edit")
          : _("Text Edit");
      }
      updateVis();
      modeToggleBtn.onclick = (e: MouseEvent) => {
        e.preventDefault();
        // If switching FROM text mode TO visual mode, sync before switching
        if (isTextMode) {
          syncFromTextMode();
        }
        isTextMode = !isTextMode;
        updateVis();
        // If switching FROM visual mode TO text mode, ensure text input is updated
        if (isTextMode) {
          const listen = listenInput.value.trim();
          const target = targetInput.value.trim();
          const protocol = protocolSelect.value;
          const frpNodes = getSelectedNodes();
          const preview_str = this.buildString({
            listenPort: listen,
            targetPort: target,
            frpNodes: frpNodes,
            protocol: protocol,
          });
          textModeInput.value = preview_str;
          previewDiv.textContent = _("Preview: %s").format(preview_str);
        }
      };

      deleteBtn.onclick = (e: MouseEvent) => {
        e.preventDefault();
        row.remove();
        // 从 rowRefs 中移除当前行的引用
        const idx = rowRefs.findIndex(
          (ref) =>
            ref.listenInput === listenInput &&
            ref.targetInput === targetInput &&
            ref.protocolSelect === protocolSelect,
        );
        if (idx !== -1) {
          rowRefs.splice(idx, 1);
        }
        updateHiddenValue();
      };

      return {
        element: row,
        listenInput,
        targetInput,
        protocolSelect,
        getSelectedNodes,
      };
    };

    for (let i = 0; i < current_values.length; i++) {
      const rowData = renderMappingRow(current_values[i], i);
      rowRefs.push(rowData);
      mappings_wrapper.appendChild(rowData.element);
    }

    const addBtn = (
      <button
        type="button"
        class="btn btn-sm btn-primary"
        style="margin-bottom: 10px;"
      >
        {_("Add Port Mapping")}
      </button>
    ) as HTMLButtonElement;

    addBtn.onclick = (e: MouseEvent) => {
      e.preventDefault();
      const new_index = rowRefs.length;
      const rowData = renderMappingRow("", new_index);
      rowRefs.push(rowData);
      mappings_wrapper.appendChild(rowData.element);
    };

    const hiddenInput = (
      <input type="hidden" name={widget_id} value={current_values.join(" ")} />
    );

    this.hiddenInput = hiddenInput as HTMLInputElement;
    const container = (
      <div class="cbi-value-field">
        {mappings_wrapper}
        {addBtn}
        {hiddenInput}
        <div class="cbi-value-description">
          {_(
            "Configure port forwarding rules. Listen Port and Target Port support single port (8080) or port range (8080-8090).",
          )}
        </div>
      </div>
    );

    return container;
  }
  cfgvalue(section_id: string) {
    const value = L.uci.get("portweaver", section_id, "port_mapping");
    if (Array.isArray(value)) return value;
    if (typeof value === "string")
      return String(value).split(/\s+/).filter(Boolean);
    return [];
  }
  formvalue(_section_id: string) {
    if (this.hiddenInput?.value) {
      const parts = this.hiddenInput.value.split(/\s+/).filter(Boolean);
      return Array.from(new Set(parts));
    }
    return null;
  }
  write(section_id: string, formvalue: string | string[]) {
    if (formvalue && formvalue.length > 0) {
      return L.uci.set("portweaver", section_id, "port_mapping", formvalue);
    } else {
      return L.uci.unset("portweaver", section_id, "port_mapping");
    }
  }
  validate(_section_id: string, value: any) {
    // 验证端口映射格式
    if (!value) {
      this.validationError = "";
      this.isValidFlag = true;
      return;
    }

    const valueStr = Array.isArray(value) ? value.join(" ") : String(value);
    const mappings = valueStr.split(/\s+/).filter(Boolean);

    for (const mappingStr of mappings) {
      const parsed = this.parseMapping(mappingStr);

      if (!parsed) {
        this.validationError = _("Invalid port mapping format");
        this.isValidFlag = false;
        return;
      }

      // 验证监听端口
      if (!parsed.listenPort) {
        this.validationError = _("Listen port is required");
        this.isValidFlag = false;
        return;
      }

      if (!this.validatePortOrRange(parsed.listenPort)) {
        this.validationError = _(
          "Invalid listen port format. Use port (8080) or range (8080-8090)",
        );
        this.isValidFlag = false;
        return;
      }

      // 验证目标端口
      if (!parsed.targetPort) {
        this.validationError = _("Target port is required");
        this.isValidFlag = false;
        return;
      }

      if (!this.validatePortOrRange(parsed.targetPort)) {
        this.validationError = _(
          "Invalid target port format. Use port (80) or range (80-90)",
        );
        this.isValidFlag = false;
        return;
      }

      // 验证端口范围匹配
      const listenPorts = this.parsePortRange(parsed.listenPort);
      const targetPorts = this.parsePortRange(parsed.targetPort);

      if (listenPorts.length !== targetPorts.length) {
        this.validationError = _(
          "Listen port range and target port range must have the same size",
        );
        this.isValidFlag = false;
        return;
      }

      // 验证 FRP 节点
      if (parsed.frpNodes && parsed.frpNodes.length > 0) {
        for (const nodeStr of parsed.frpNodes) {
          const [node, port] = nodeStr.split(":");

          if (!node) {
            this.validationError = _("Invalid FRP node format");
            this.isValidFlag = false;
            return;
          }

          if (port) {
            const portNum = parseInt(port, 10);
            if (Number.isNaN(portNum) || portNum < 1 || portNum > 65535) {
              this.validationError = _(
                "FRP node port must be between 1 and 65535",
              );
              this.isValidFlag = false;
              return;
            }
          }
        }
      }

      // 验证协议
      if (
        parsed.protocol &&
        !["tcp", "udp", "both"].includes(parsed.protocol)
      ) {
        this.validationError = _("Protocol must be `tcp`, `udp`, or `both`");
        this.isValidFlag = false;
        return;
      }
    }

    this.validationError = "";
    this.isValidFlag = true;
  }
  private validatePortOrRange(portStr: string): boolean {
    // 验证单个端口或端口范围
    if (!portStr) return false;

    // 单个端口
    if (/^\d+$/.test(portStr)) {
      const port = parseInt(portStr, 10);
      return port >= 1 && port <= 65535;
    }

    // 端口范围
    if (/^\d+-\d+$/.test(portStr)) {
      const [start, end] = portStr.split("-").map((p) => parseInt(p, 10));
      return (
        start >= 1 && start <= 65535 && end >= 1 && end <= 65535 && start <= end
      );
    }

    return false;
  }

  private parsePortRange(portStr: string): number[] {
    // 解析端口或端口范围，返回端口数组
    if (/^\d+$/.test(portStr)) {
      return [parseInt(portStr, 10)];
    }

    if (/^\d+-\d+$/.test(portStr)) {
      const [start, end] = portStr.split("-").map((p) => parseInt(p, 10));
      const ports: number[] = [];
      for (let i = start; i <= end; i++) {
        ports.push(i);
      }
      return ports;
    }

    return [];
  }

  isValid(section_id: string): boolean {
    for (const errorEl of this.errorDivRefs) {
      const isVisible = errorEl.style.display !== "none";
      const hasText = errorEl.textContent && errorEl.textContent.trim() !== "";

      if (isVisible && hasText) {
        this.validationError = errorEl.textContent || _("Validation failed");
        this.isValidFlag = false;
        return false;
      }
    }

    const value = this.formvalue(section_id);
    this.validate(section_id, value);
    return this.isValidFlag ?? true;
  }

  getValidationError(section_id: string): string {
    if (!this.isValid(section_id)) {
      return this.validationError || _("Validation failed");
    }
    return "";
  }

  private validationError: string = "";
  private isValidFlag: boolean = true;
}
export default PortMappingEditor;
