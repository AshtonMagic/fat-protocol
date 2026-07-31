---
eip: TBD
title: Fungible Agent Tokens（FAT）协议
description: 一份让 AI agent 作为链上经济主体发行自身权益的最小化标准——在同一套接口里统一自主执行、权益发行与可验证的推理存证。
discussions-to: TBD
status: Draft
type: Standards Track
category: ERC
created: 2026-04-24
requires: 20
---

# Fungible Agent Tokens（FAT）协议

> 本文档为英文版 [`fat-protocol-spec.md`](fat-protocol-spec.md) 的中文翻译。如出现歧义，以英文版为准。

## 摘要（Abstract）

**FAT（Fungible Agent Tokens）** 是一套把 AI agent 定义为链上经济主体的权益标准。一个 FAT Agent 不是持有资金的容器，而是一个自主的行动者：它**发行**代表自身经济权益的份额、在设定的边界内**自主行动**、并为每一次行动留下**防篡改的推理记录**。协议把这三个层面统一进同一套接口：

- **自主执行** —— agent 经由其 Executor 在链上行动，与外部协议交互、运用自身资金；
- **权益发行** —— agent 发行同质化**份额（Shares）**，代表对其经济成果的参与权益，按标准兑换率进出；
- **推理存证** —— 链下元数据与逐动作的推理记录，把 agent 的身份、策略、模型与每一次决策的理由锚定到其链上身份。

借此，任何 agent 都能作为独立经济主体**诞生、接纳出资、自主运营**，并作为可组合的链上原语被整个生态调用。

具体而言，FAT Agent 是这样的合约：
- 通过两阶段"申请→领取"流程，接纳以一种 **Accept Token**（部署时指定、之后不可变的 ERC-20）计价的出资，并发行同质化**份额（Shares）**；
- 允许持有者通过"申请→领取"流程兑回 Accept Token：份额先被托管，在结算时销毁；
- 暴露一个链上标准的"份额 ↔ Accept Token"**兑换率（exchangeRate）**；
- 携带一个可变的 **Agent URI**，指向链下元数据（名称、描述、图片等）；
- 允许一个指定的链下 **Executor** 通过一个底层调用原语以 Agent 身份调用第三方协议，受 `DELEGATECALL` 禁令与 Owner 设定的 `isInScope` 门约束；
- 通过**带推理的结算**（`settleMint` / `settleRedeem`）对铸造/赎回作出自主决定——接纳、定价或拒绝每一笔出资与退出都是 agent 的一次深思熟虑之举——并为每一次链上 agent 动作附上**防篡改的推理记录**（`reasoningHash` + `reasoningURI`）。

这里所说的 **Fungible Agent Tokens**，就是那些代表 Agent 经济权益的同质化**份额（Shares）**——而非 Agent 的链下身份、模型或行为本身。后者并未被排除在标准之外，只是**不以同质化份额的形式表示**：它们由存证层负责，通过 **Agent URI** 与 `reasoningHash` / `reasoningURI` 锚定上链。

本标准固化以上接口面，但**刻意**把以下全部交由实现者决定：份额定价公式、费率大小、份额可转让性、所有权转让机制、是否及如何暂停 Agent、Holder 是否在兑换率反映之外另有收益领取通道、以及 —— 很重要的一点 —— **对 `execute` 可调用对象的任何限制**。接口与策略分离。

## 动机（Motivation）

AI agent 正越来越多地在链上行动 —— 交易、质押、借贷、管理资金 —— 然而并没有一个标准能把 agent *本身*确立为链上经济主体：可接纳出资、自主运营、被生态组合，且其行为与推理对任何人都清晰可见。把池化的资本表示成同质化份额，早已是成熟做法；真正没有标准的是 agent 那一部分——它如何在外部协议上*行动*，以及这些行动背后的链下推理如何被*锚定*上链。

FAT 定义的不是一个存放资金的容器，而是一个链上经济主体的诞生方式。一个 FAT Agent 拥有持久的链上身份、支配自身的资金、在 Owner 设定的宪法边界内自主行动，并为每一次行动署名留证。用户购买份额，不是雇佣一个替自己跑腿的执行工具，而是投资这个 agent 自身的经济活动——参与它的成长，分享它的成果。份额会计因此只是三层之一——权益发行——与该 agent 的自主执行、及其身份与推理的链下存证并列。这类系统要想可组合、可审计，行为层就需要一个标准：一个统一的接口，让工具、索引器、钱包、审计师不论 Agent 选择什么经济模型都能以同样方式观察与管理它。

本标准把 **agent 本身**作为一等公民。它的**反应**（带推理的结算，使铸造与赎回成为 Agent 自身的深思熟虑之举，而非被动记账）、它的**推理**（一份防篡改、可索引、绑定到每一次链上动作的记录）、以及它的**受限支出**（一个 Agent 自身无法放宽的、由 Owner 设定的 Scope），各自成为独立的标准接口面 —— 从而使 Agent *决定做什么*、*被允许做什么*，与它*持有什么*一样清晰可审计。

除了行为层，FAT Agent 还需要：

- **固定的计价单位** —— 即单一的 **Accept Token**，部署时选定、之后不可变，使份额定价与赎回明确无歧义。
- **标准的退出路径** —— 即统一的 `requestRedeem` / `redeem` 赎回流程，让 Holder 用同一套接口退出任意 Agent，供组合管理工具统一对接。
- **可发现的元数据指针** —— 即 **Agent URI**，类比 ERC-721 `tokenURI`，让浏览器和市场无需逐个项目集成就能渲染 Agent 身份信息。

由于结算可能是异步的——用户先申请，待 Agent 就绪后再领取——份额的铸造与赎回采用两阶段"申请→领取"生命周期，而非单笔同步调用。

本规范将以上所有能力组织为一套最小可组合的标准。

## 规范（Specification）

本文档中的关键词 "必须（MUST）"、"不得（MUST NOT）"、"必需（REQUIRED）"、"SHALL"、"SHALL NOT"、"应当（SHOULD）"、"不应（SHOULD NOT）"、"推荐（RECOMMENDED）"、"可以（MAY）"、"可选（OPTIONAL）" 的理解遵循 RFC 2119。

### 1. 合规性（Conformance）

当一份合约同时满足以下条件时，称其 **FAT 合规**：
- 实现 §4 定义的 `IAgent` 接口；
- 发出 §5 定义的事件；
- 遵守 §3 定义的角色语义；
- 满足 §6 的全部规范性要求（§6.8 重入为安全建议，而非合规必要条件）；
- 通过 ERC-165 声明其对 FAT 的支持，以便接口探测（见向后兼容性段）。
- 实现 `settleMint`、`settleRedeem`、`isInScope`，以及带推理的 `execute`（§4）；
- 在每次 `settleMint` / `settleRedeem` / `execute` 上携带非零 `reasoningHash` 与非空、可解析的 `reasoningURI`，并发出对应的带推理事件（§6.2）；
- 在 `execute` 上强制 `isInScope`，且 Scope 仅 Owner 可配置（§6.6.7–8）。

合规 Agent **必须**为其份额代币实现 ERC-20。份额代币**可以**就是 Agent 合约本身，也**可以**是另一个合约；无论哪种，`shareToken()` **必须**返回其地址。

### 2. 术语（Terminology）

- **Agent** — 一份 FAT 合规的合约：链下 agent 的链上化身（on-chain embodiment），一个拥有资产、发行权益、自主行动并对自身行为留证的链上经济主体。Agent 合约**就是**该 agent 的链上账户——一个持久、稳定的地址，支配自身资金、发行代表自身的份额、通过其 Executor 行动、并对外呈现其身份。Agent 合约连同它的 `agentURI` 存证，共同标识这个链上 agent——行动的账户，加上"它是什么"的链下记录。（Executor 只是被授权驱动这个账户的 key，而非身份本身。）
- **份额（Share）** — 由 Agent 发行的一份权益，代表对其经济成果的参与，以 ERC-20 实现。
- **Accept Token** — Agent 所接受的**唯一一种** ERC-20，用于铸造新份额、赎回支付。**部署时确定，Agent 生命周期内不可变。**
- **Owner** — Agent 的宪法设定者与监护人：设定 agent 自身无法放宽的行动边界（Scope）、任免 Executor、维护 Agent URI。**可以**是 EOA、多签或治理合约。协议不规定 Owner 是否及如何退出（见 §6.7、§7）；一个 Owner 被弃置或 renounce 的 Agent，即在其固化的宪法内完全自治地运行。
- **Executor（执行体）** — agent 意志的链上执行通道：既经 `settleMint` / `settleRedeem` 对出资与退出作出结算决定，也经 `execute` 将 agent 的行动提交上链。每一次这样的动作都带有推理（§6.2）。一个 Agent **可以**有零个或多个 Executor。同一个地址**可以**同时是 Owner 和 Executor。Executor 不能更改 Scope，也不能更改 Owner。由于 `execute` 会把任意 calldata 转发到任意 Executor 选择的 target（仅受 §6.6.2 `DELEGATECALL` 禁令约束），Executor 实际上是一个无约束角色，覆盖 Agent 持有的每一项资产以及 Agent 能签发的每一项授权——仅受 Owner 配置的 Scope 约束（`isInScope`，§6.6.7–8）。
- **Holder（持有者）** — 任何持有非零份额的地址。
- **Request（请求）** — 一个待结算或可领取的 mint / redeem 操作。请求按发起人同质化：一个发起人**可以**先后开启多笔，但它们以聚合方式（一个待结算额、一个可领取额）记账，而非逐笔单独寻址。见 §6.3、§6.4。
- **Requester（请求发起人）** — 开启请求的地址（`requestMint` / `requestRedeem` 的调用者），也是领取时的收款方。与 Agent 的 **Owner** 角色相区分。
- **Epoch（结算轮次）** — 一个由实现方定义的结算批次序号，出现在生命周期事件（`MintRequested`、`SharesMinted`、`RedeemRequested`、`SharesRedeemed`）中，供索引器把请求与领取关联到它们所属的结算轮次。不做批处理的逐请求或固定价 Agent **可以**用单调计数器或 `0`；协议不强制任何 epoch 或批处理机制（§6.3.3）。
- **Agent URI** — 一个链下 URI（通常是 `ipfs://`、`https://`、`ar://` 或 `data:`），解析为描述 Agent 的 JSON 元数据（身份、策略、模型等）——即 agent 的链下存证。详见 §6.5。
- **兑换率（Exchange Rate）** — 一份 Share 当前折合多少 Accept Token 的标准数值，以 `1e18` 作定点缩放；是供估值用的 NAV 参考，通过 `exchangeRate()` 读取。准确地说，`exchangeRate()` 返回 `R`，使得 `x` 份额最小单位（wei）的参考价值为 `x * R / 1e18` 个 Accept Token 最小单位（wei）——即 wei-to-wei 的定点比率，18 位缩放。可领取的份额数量/赔付在结算时固定，由 `queryMintStatus` / `queryRedeemStatus` 给出，二者**可以**与该兑换率存在偏差。
- **推理记录（Reasoning record）** — reasoningURI 解析出的链下内容，由 reasoningHash 在链上承诺（§6.2）。
- **支出范围（Scope）** — Owner 配置的边界，Executor 只能在其内经 execute 支出，由 isInScope 强制（§6.6.7–8）。

### 3. 角色（Roles）

FAT 严格定义三个角色。实现**可以**增加额外角色（例如 Guardian、Fee Recipient、Pauser、Policy Oracle），但**不得**削弱下述三个角色的规范性权限。

| 角色     | 必需能力                                                     | 用户承担的信任前提 |
|----------|--------------------------------------------------------------|--------------------|
| Owner    | 增删执行体；设置 Agent URI；配置 Executor 的支出 Scope。      | Holder 与 Requester 信任 Owner 不会启用恶意 Executor、不会把 Agent URI 指向误导性元数据。 |
| Executor | 结算待处理请求（`settleMint` / `settleRedeem`）并以 Agent 身份调用 `execute`——每一次这样的动作都带有推理；`execute` 必须通过 Owner 设定的 Scope。 | 对 Agent 持有的每一项资产与能签发的每一项授权实际无约束（§2、§6.6），受 Owner 设定的 Scope 约束；集成方必须信任 Executor 的运维状况。 |
| Holder   | 持有份额；以及（由实现者选择是否允许）转让份额。             | — |

mint/redeem 生命周期分两个阶段——开启请求与随后领取——两者都不需要特权角色授予（不涉及 Owner 或 Executor 权限），但在"谁能调用"上不同。**开启**请求仅限本人，且受限于调用者自己已经持有的资产：`requestMint` 花的是调用者自己的 Accept Token，`requestRedeem` 托管的是调用者自己的份额（因此赎回的发起人必须已经是 Holder）。无法代表其他地址开启请求——那需要授权，已刻意排除（见 §7 与设计理由段）。开启请求的地址即 §2 所称的 **Requester**。**领取**则相反，是任何人都能触发的无许可操作：`mint(user)` / `redeem(user)` 任何地址都可以调用、替应得方触发，但款项永远付给 `user`（应得方），因此调用者无利可图，也就不需要授权。铸造的发起人不必已经是 Holder（一笔待结算的铸造尚无份额）；Requester 隐式接受 Agent 在结算时固定的结算价，因为领取不带滑点保护（§6.3、§6.4、§7）。本标准不把 Requester 升为独立的信任角色，这正是只列三个角色的原因。

这些角色是能力，而非互斥的主体：协议并不要求它们由不同地址持有，因此一个地址可以同时担任多个。其中 Owner 与 Executor 是**特权、受信任**角色，担任 Holder 或 Requester 则是**无许可**的。把特权角色（Owner 与 Executor）集中在一个地址、或让 Owner/Executor 自己也持有 Holder/Requester 头寸，会使 Agent 的外部 Holder 必须付出的信任达到最大，并制造围绕结算的自我交易动机；见安全考量段。实现**可以**作为策略限制其允许的角色组合；本标准既不强制也不禁止某种特定的分离。Executor 经 `execute` 的支出受 Owner 配置的 Scope 约束（由 `isInScope` 强制，§6.6.7–8），而每一次 agent 动作——无论结算还是执行——都带有推理（§6.2）。

### 4. 接口（Interface）

所有合规 Agent **必须**实现以下 Solidity 接口。函数签名、参数顺序、返回值类型均为规范性要求。

```solidity
// SPDX-License-Identifier: CC0-1.0
pragma solidity >=0.8.20;

interface IAgent {
    // ---------- Immutable configuration ----------

    /// @notice 唯一被接受的 ERC-20：用于份额铸造、赎回支付。
    /// @dev    在 Agent 整个生命周期内，本函数必须返回同一地址。
    function acceptToken() external view returns (address);

    /// @notice 份额代币（ERC-20）的地址。
    /// @dev    若 Agent 自身即 ERC-20，可以返回 `address(this)`。
    function shareToken() external view returns (address);

    // ---------- 份额铸造（两阶段） ----------

    /// @notice 第一阶段。存入 `amount` 数量的 Accept Token，计入调用者的待结算铸造额。
    /// @dev    必须通过 ERC-20 `transferFrom` 精确拉取 `amount`；不得接受原生以太币。
    ///         份额数量稍后在结算时确定。必须 emit `MintRequested`。
    /// @param amount  要存入的 Accept Token 数量（最小单位）。
    function requestMint(uint256 amount) external;

    /// @notice 第二阶段。一次性领取 `user` 当前全部可领取的份额。无许可：任何调用者都可以触发领取，
    ///         但份额始终铸给 `user`（应得方），因此调用者只付 gas、无利可图。
    /// @dev    必须把 `user` 全部可领取份额铸给 `user`、将该余额清零，并 emit `SharesMinted`。
    ///         不带滑点保护：份额数已在结算时确定（见 §6.3），领取只是把应得的份额收走，结算价隐式接受。
    /// @param  user    应得方，其可领取份额被铸给它自己。自领时传入自己的地址。
    /// @return shares  铸造给 `user` 的份额数量（若无可领取额则为 0）。
    function mint(address user) external returns (uint256 shares);

    /// @notice Agent 反应。结算 `requester` 的待结算 mint 请求，附带推理。
    /// @dev    Executor 专用。把 `requester` 的部分/全部/零 pendingAssets 结算进 claimableShares；
    ///         金额/接受/定价由实现方在函数体内算。必须 emit `Settled`。reasoningHash/reasoningURI 见 §6.2。
    /// @param  requester      要结算的请求。
    /// @param  reasoningHash  `reasoningURI` 处字节的 keccak256；必须非零。
    /// @param  reasoningURI   指向推理记录的可解析指针；必须非空。
    function settleMint(address requester, bytes32 reasoningHash, string calldata reasoningURI) external;

    /// @notice 查询 `user` 的聚合铸造状态。
    /// @return pendingAssets    已存入但尚未结算的 Accept Token。
    /// @return claimableShares  已结算、等待 `mint` 领取的份额。
    function queryMintStatus(address user)
        external
        view
        returns (uint256 pendingAssets, uint256 claimableShares);

    // ---------- 份额赎回（两阶段） ----------

    /// @notice 第一阶段。托管 `shares` 份额，计入调用者的待结算赎回额。
    /// @dev    必须从 `msg.sender` 精确拉取（托管）`shares` 份额代币。
    ///         已结算的份额在结算时销毁；赔付在结算时定价。必须 emit `RedeemRequested`。
    /// @param shares  要赎回的份额数量。
    function requestRedeem(uint256 shares) external;

    /// @notice 第二阶段。一次性领取 `user` 当前全部可领取的 Accept Token。无许可：任何调用者都可以触发领取，
    ///         但 Accept Token 始终付给 `user`（应得方），因此调用者只付 gas、无利可图。
    /// @dev    必须把 `user` 全部可领取的 Accept Token 转给 `user`、将该余额清零，并 emit `SharesRedeemed`。
    ///         不带滑点保护：赔付已在结算时确定（见 §6.4），领取只是把应得的代币收走，结算价隐式接受。
    /// @param  user    应得方，Accept Token 付给它。自领时传入自己的地址。
    /// @return tokens  转给 `user` 的 Accept Token 数量（若无可领取额则为 0）。
    function redeem(address user) external returns (uint256 tokens);

    /// @notice Agent 反应。结算 `requester` 的待结算 redeem 请求，附带推理。
    /// @dev    Executor 专用。与 settleMint 对称：把 pendingShares 结算进 claimableTokens，
    ///         并销毁已结算份额。必须 emit `Settled`。
    function settleRedeem(address requester, bytes32 reasoningHash, string calldata reasoningURI) external;

    /// @notice 查询 `user` 的聚合赎回状态。
    /// @return pendingShares    已托管但尚未结算的份额。
    /// @return claimableTokens  已结算、等待 `redeem` 领取的 Accept Token。
    function queryRedeemStatus(address user)
        external
        view
        returns (uint256 pendingShares, uint256 claimableTokens);

    // ---------- 兑换率 ----------

    /// @notice 标准估值率：1 份份额当前折合多少 Accept Token，以 1e18 定点缩放。
    /// @dev    供工具与持仓估值使用的份额估值 / NAV 参考。固定价 Agent 可以恒为常量；
    ///         NAV 型 Agent 随时间变化。它**不是** mint/redeem 成交结果的预测——
    ///         成交结果在结算时固定，由 `queryMintStatus` / `queryRedeemStatus` 给出。
    /// @return rate   每 1e18 份额最小单位折合的 Accept Token 最小单位（wei-to-wei），18 位定点：
    ///                `x` 份额最小单位的参考价值为 `x * rate / 1e18` 个 Accept Token 最小单位。
    function exchangeRate() external view returns (uint256 rate);

    // ---------- Agent 元数据 ----------

    /// @notice 描述 Agent 的链下 JSON 元数据 URI。
    function agentURI() external view returns (string memory);

    /// @notice 设置 Agent URI。仅 Owner 可调。必须 emit `AgentURIUpdated`。
    function setAgentURI(string calldata uri) external;

    // ---------- 执行体分发 ----------

    /// @notice 执行体分发，附带推理与 scope 强制。
    /// @dev    若 `msg.sender` 不是 Executor 必须 revert。
    ///         不得以 `DELEGATECALL` 分发（见 §6.6.2）。
    ///         不得为 `payable`；`value` 从 Agent 自身余额支付（见 §6.6.4）。
    ///         必须调用 `isInScope(target, value, data)`，返回 false 则 revert（见 §6.6.7）。
    ///         失败时必须把原始 revert data 原样抛出（此时不发任何事件）。
    ///         成功时必须 emit `Executed`（带推理）。
    ///         reasoningHash/reasoningURI 见 §6.2。
    ///         除 Executor 检查、`DELEGATECALL` 禁令与 `isInScope` 门控外，
    ///         实现者可以在本函数之上叠加任何其他策略（target 白名单、selector 过滤、
    ///         参数过滤、session key、签名策略引擎、外部策略合约、速率限制等）。
    function execute(
        address target, uint256 value, bytes calldata data,
        bytes32 reasoningHash, string calldata reasoningURI
    ) external returns (bytes memory returnData);

    // ---------- Owner 管理 ----------

    /// @notice 启用或停用 `account` 作为 Executor。仅 Owner 可调。必须 emit `ExecutorUpdated`。
    function setExecutor(address account, bool enabled) external;

    // ---------- Views ----------

    /// @notice 当前有权调用 Owner 级函数的地址。
    /// @dev    该地址如何变更，不在本规范范围内。
    function owner() external view returns (address);

    function isExecutor(address account) external view returns (bool);

    /// @notice 一次 `execute(target, value, data)` 是否落在 Agent 的支出 scope 内。
    /// @dev    实现方定义的 predicate；`execute` 必须咨询它（§6.6.7）。其反映的 scope 仅 Owner 可配置（§6.6.8）。
    ///         也可用作链下审计查询。
    function isInScope(address target, uint256 value, bytes calldata data) external view returns (bool);
}
```

### 5. 事件（Events）

以下事件均为规范性要求。凭 `MintRequested`、`SharesMinted`、`RedeemRequested`、`SharesRedeemed`、`Settled`、`Executed`（外加份额代币的 ERC-20 事件），索引器可追踪每一笔存入、结算、领取与执行体调用。Agent 的推理锚定在 `Settled` 与 `Executed` 之上，通过其 `reasoningHash` / `reasoningURI` 字段（对实现方自定义的 agent 函数，则通过 `Reasoned`）承载。由于结算**可以**以聚合方式而非逐发起人上报（§6.3、§6.4），某发起人当前的 `pendingAssets` / `claimableShares`（以及 `pendingShares` / `claimableTokens`）以 `queryMintStatus` / `queryRedeemStatus` 视图为权威，而非仅凭事件重建。`acceptToken()` 与 `shareToken()` 作为部署数据的一部分，不需要运行时事件。所有权转让事件、暂停/恢复事件（若有）由各实现自行定义（§6.7、§7）。

```solidity
event MintRequested(
    address indexed requester,
    uint256         assets,      // 存入的 Accept Token
    uint64  indexed epoch,       // 结算批次序号（§2）；可以为 0
    uint256         timestamp    // emit 时的 block.timestamp
);

event RedeemRequested(
    address indexed requester,
    uint256         shares,      // 托管的份额
    uint64  indexed epoch,       // 结算批次序号（§2）；可以为 0
    uint256         timestamp    // emit 时的 block.timestamp
);

event SharesMinted(             // 领取时 emit
    address indexed requester,
    uint256         assets,      // 产生所领份额的 Accept Token
    uint256         shares,      // 铸给 requester 的份额
    uint64  indexed epoch,       // 所含最近的结算 epoch；可以为 0
    uint256         sharePrice,  // 有效结算价：assets * 1e18 / shares
    uint256         timestamp    // emit 时的 block.timestamp
);

event SharesRedeemed(           // 领取时 emit
    address indexed requester,
    uint256         shares,      // 为产生赔付而赎回的份额
    uint256         assets,      // 赔付的 Accept Token
    uint64  indexed epoch,       // 所含最近的结算 epoch；可以为 0
    uint256         sharePrice,  // 有效结算价：assets * 1e18 / shares
    uint256         timestamp    // emit 时的 block.timestamp
);

/// 每当 `exchangeRate()` 变化（如 NAV 结算）时 SHOULD emit。
/// 恒定价（固定价）Agent 可以从不 emit。它是 NAV 型 Agent 的 O(1) 结算信号——见 §6.3.4 / §6.4.4。
event ExchangeRateUpdated(uint256 newRate);

event AgentURIUpdated(string newURI);

event Executed(
    address indexed executor,
    address indexed target,
    uint256         value,
    bytes4  indexed selector,   // calldata 前 4 字节；data.length < 4 时为 0x00000000
    bytes           returnData,
    bytes32         reasoningHash,
    string          reasoningURI
);

/// 当 Executor 结算一笔待结算请求时 emit（§6.3、§6.4）。
event Settled(
    address indexed requester,
    uint8           kind,          // 0 = mint，1 = redeem
    uint256         amount,        // 变为可领取的份额（mint）或代币（redeem）
    bytes32 indexed reasoningHash,
    string          reasoningURI
);

/// 实现方自有的 agent 函数 SHOULD emit 它以统一附带推理。标准操作（settleMint/settleRedeem/execute）在自己的事件里带推理。
event Reasoned(
    address indexed actor,
    bytes4  indexed action,
    bytes32 indexed reasoningHash,
    string          reasoningURI
);

event ExecutorUpdated(address indexed executor, bool enabled);
```

`SharesMinted` / `SharesRedeemed` 在为某 requester 领取时 emit——通过 `mint(user)` / `redeem(user)`，任何地址都**可以**调用（见 §6.3.5、§6.4.5）；被索引的地址始终是应得方。存入 / 赎回只有在 Executor 通过 `settleMint` / `settleRedeem` 结算后才变为可领取（§6.3、§6.4），并由 `queryMintStatus` / `queryRedeemStatus` 报告。由于一次领取会收走 requester **全部**可领取余额，而这可能跨越不止一次结算，这两个事件上的 `assets` / `shares` / `sharePrice` / `epoch` 字段报告的是聚合值：`assets` 与 `shares` 是本次领取所换算的总量，`sharePrice` 是有效价率 `assets * 1e18 / shares`（`shares` 为 `0` 时取 `0`），`epoch` 是所含最近的结算 epoch。四个生命周期事件上的 `timestamp` 均为 emit 时的 `block.timestamp`——与日志元数据重复，仅为索引便利。

### 6. 规范性要求（Normative Requirements）

#### 6.1 不变量（Invariants）

1. `acceptToken()` 与 `shareToken()` 在 Agent 整个生命周期内**必须**各自返回同一地址。
2. Accept Token 为单一一种 ERC-20；Agent **不得**接受原生以太币作为份额的支付（§6.3.1）。
3. §3 的角色语义在 Agent 整个生命周期内**必须**保持可强制执行：`owner()` **必须**始终报告当前管理地址，`execute` **必须**始终强制执行 Executor 检查（§6.6.1）、`DELEGATECALL` 禁令（§6.6.2）与 `isInScope` 门（§6.6.7）。

#### 6.2 带推理的 agent 动作

某些函数是 **agent 动作**：由 Executor 代表 Agent 发起的状态变更调用 —— `settleMint`、`settleRedeem`、`execute`，以及任何实现方自定义的、面向 agent 的函数。每个标准 agent 动作都携带 `bytes32 reasoningHash` 与 `string reasoningURI`：

1. `reasoningHash` **必须**非零，且**必须**等于 `keccak256(b)`，其中 `b` 是 `reasoningURI` 解析出的精确字节串。
2. `reasoningURI` **必须**非空，且**必须**在动作发生时即可解析到该内容。不支持延迟揭示；若需要先私有后公开的推理，应采用内容寻址方案（`ipfs://`、`ar://`），并在动作发生之前或同时发布。
3. `reasoningURI` 遵循 §6.5 的 Agent URI 约定（scheme；**推荐**内容寻址）。它**应当**解析到一份 UTF-8 JSON 文档，携带信封标记 `"schema": "fat-reasoning/1"`；消费者**必须**忽略未知字段。领域字段（`model`、`prompt`、`inputs`、`trace`、`decision`……）由实现方自定义。
4. 推理**必须**锚定在该动作的标准事件中（结算用 `Settled`，`execute` 用 `Executed`）。实现方自定义的 agent 函数**应当** emit `Reasoned`。
5. 推理是一条防篡改的审计轨迹，而非被强制执行的保证：它只证明某条推理记录被提交且未被改动，并不证明该动作确实由它推导而来（见安全考量段）。

#### 6.3 份额铸造（两阶段：`requestMint` → `mint`）

1. `requestMint(amount)` **必须**通过 ERC-20 `transferFrom` 从 `msg.sender` 精确拉取 `amount` 数量的 `acceptToken()`；**不得**接受原生以太币。若 Accept Token 为 fee-on-transfer 或 rebasing 代币，实际收到的数量**可以**与 `amount` 不同；支持此类代币的 Agent **必须**在文档中说明它如何把发起人的 `pendingAssets` 与实际收到的余额对账，不支持此类代币的 Agent **必须**在文档中声明不支持 fee-on-transfer / rebasing Accept Token。
2. `requestMint` **必须**把 `amount` 计入调用者的待结算铸造额，并 emit `MintRequested(msg.sender, amount, epoch, block.timestamp)`（`epoch` 为 Agent 当前结算轮次，§2；**可以**为 `0`）。请求不单独寻址；某发起人的待结算存款以聚合方式记账，由 `queryMintStatus` 以 `pendingAssets` 报告。
3. 待结算存款何时、如何变为可领取 —— 运营方履约、时间延迟、NAV/周期收盘、流动性到位 —— 由实现者决定，不在本规范范围内（§7）。
4. 某发起人待结算铸造的结算由 Executor 调用 `settleMint(requester, reasoningHash, reasoningURI)` 执行，按 §6.2 携带推理。它把该发起人 `pendingAssets` 的部分、全部或零结算进 `claimableShares`（结算零 = 拒绝/延后；请求保持待结算，或经 §6.4.6 的可选取消路径退款）。已结算存款到 `shares` 的映射公式（定价/额度/是否接受）由实现者决定，并在 `settleMint` 内部计算；它**可以**从存款中扣留 Owner 费用（是否收费、费率大小与去向均由实现者决定，§7）。由于金额由合约逻辑计算而非调用方提供，Executor 无法铸造任意数量。结算时，结算出的 `shares` **必须**被固定，且 `queryMintStatus(requester)` **必须**反映出已结算部分从 `pendingAssets` 转入 `claimableShares`。`settleMint` **必须** emit `Settled(requester, 0, shares, reasoningHash, reasoningURI)`。`exchangeRate()` 在结算时变化的 Agent **应当** emit `ExchangeRateUpdated`。逐请求结算是有意为之——它使 Executor 能对每个发起人施加 KYC、风控或差异化定价——且结算 gas 随请求数量增长；实现**可以**添加一个由实现者定义的批量封装以摊薄该成本。
5. `mint(user)` **可以**由任何地址调用（无许可领取：任何人都可替应得方触发）；它**必须**把 `user` 全部可领取份额铸给 `user`，**必须**将该余额清零，并**必须** emit `SharesMinted(user, assets, shares, epoch, sharePrice, block.timestamp)`（字段见 §5）。因为赔付永远付给 `user`（应得方），调用者无利可图、也无需任何授权。它不带滑点参数：`shares` 已在结算时（第 4 条）固定，因此领取只是把 `user` 应得的份额收走，`mint(user)` **不得**因结算出的金额而 revert。若 `user` 无可领取额，`mint(user)` 返回 `0`。

#### 6.4 份额赎回（两阶段：`requestRedeem` → `redeem`）

1. `requestRedeem(shares)` **必须**从 `msg.sender` 精确拉取（托管）`shares` 份额代币到 Agent 中，并计入调用者的待结算赎回额。
2. `requestRedeem` **必须** emit `RedeemRequested(msg.sender, shares, epoch, block.timestamp)`（`epoch` 为 Agent 当前结算轮次，§2；**可以**为 `0`）。请求不单独寻址；某发起人的待结算托管份额以聚合方式记账，由 `queryRedeemStatus` 以 `pendingShares` 报告。
3. 待结算托管份额何时、如何变为可领取 由实现者决定，不在本规范范围内（§6.3.3、§7）。当下无法满足赎回的 Agent（例如 Accept Token 已全部部署到外部协议）只需让份额保持待结算，直到流动性允许结算；该两阶段流程即协议的延迟流动性机制。协议**不强制**任何特定的结算时机、队列或缓冲，只要 Holder 最终存在兑现份额 Accept Token 价值的路径。
4. 某发起人待结算赎回的结算由 Executor 调用 `settleRedeem(requester, reasoningHash, reasoningURI)` 执行，按 §6.2 携带推理。它把该发起人 `pendingShares` 的部分、全部或零结算进 `claimableTokens`（结算零 = 拒绝/延后；请求保持待结算，或经 §6.4.6 的可选取消路径退款），并销毁已结算的份额（在结算时聚合销毁，或在对应领取时销毁）。`shares` 到 `tokens` 的映射公式由实现者决定，并在 `settleRedeem` 内部计算；它**可以**扣留 Owner 费用（是否收费及费率大小均由实现者决定，§7）。由于金额由合约逻辑计算而非调用方提供，Executor 无法支付任意数量。结算时，结算出的 `tokens` **必须**被固定，且 `queryRedeemStatus(requester)` **必须**反映出已结算部分从 `pendingShares` 转入 `claimableTokens`。`settleRedeem` **必须** emit `Settled(requester, 1, tokens, reasoningHash, reasoningURI)`。`exchangeRate()` 在结算时变化的 Agent **应当** emit `ExchangeRateUpdated`。与铸造（§6.3.4）一样，逐请求结算是有意为之（KYC / 风控 / 差异化定价），且结算 gas 随请求数量增长；实现**可以**添加一个由实现者定义的批量封装以摊薄该成本。
5. `redeem(user)` **可以**由任何地址调用（无许可领取：任何人都可替应得方触发）；它**必须**把 `user` 全部可领取代币额的 `acceptToken()` 转给 `user`，**必须**将该余额清零，并**必须** emit `SharesRedeemed(user, shares, tokens, epoch, sharePrice, block.timestamp)`（字段见 §5）。因为赔付永远付给 `user`（应得方），调用者无利可图、也无需任何授权。它不带滑点参数：`tokens` 已在结算时（第 4 条）固定，因此领取只是把 `user` 应得的代币收走，`redeem(user)` **不得**因结算出的金额而 revert。若 `user` 无可领取额，`redeem(user)` 返回 `0`。
6. 请求取消与请求过期 / TTL 为**可选**、由实现者决定（§7）。支持取消或过期的 Agent **必须**把仍处于待结算的托管份额（赎回）或仍处于待结算的已存入 Accept Token（铸造）退还给 requester；已结算（可领取）的余额不受影响。此类 Agent **应当**自定义取消事件。
7. 当余额处于待结算时，已存入的 Accept Token（铸造）留在 Agent 中，被托管的份额（赎回）被持有但尚未销毁。这些在途余额在待结算窗口期内如何计入 `exchangeRate()` / NAV，由实现者决定（§7）；实现**应当**在文档中声明其处理方式，以使估值无歧义。

**判断是否还有待领取项。** 调用方（例如前端）通过读 `queryMintStatus(user)` / `queryRedeemStatus(user)` 判断是否还需要单独调用 `mint` / `redeem`：`claimableShares` / `claimableTokens` 为正，表示有可立即领取的份额/代币；`pendingAssets` / `pendingShares` 为正，表示仍在等待结算（稍后再领）；两者都为零，表示没有未决项（已领取完毕，或从未发起请求）（§6.3.3、§6.4.3）。

#### 6.5 Agent URI

1. `agentURI()` **必须**返回 Agent 当前的 URI 字符串。Agent **可以**以空串（`""`）作为部署初值；Owner **应当**在公开使用前设置非空 URI。
2. `setAgentURI(uri)` **必须**仅 Owner 可调，且**必须** emit `AgentURIUpdated(uri)`。
3. URI **应当**解析为 UTF-8 JSON 文档。消费者**必须**忽略未知字段。文档**应当**至少包含：

    ```json
    {
      "name":         "字符串，人类可读的 Agent 名称",
      "description":  "字符串，Agent 简要描述",
      "image":        "字符串，用于展示的代表性图片 URI",
      "external_url": "字符串，可选 —— 项目主页或档案页",
      "properties":   { "键": "实现自定义的自由字段" }
    }
    ```

4. URI scheme **应当**是 `ipfs://`、`https://`、`ar://` 或 `data:application/json;base64,…`（完全上链的元数据）之一。Agent **不得**要求特定 scheme；消费者**必须**接受任何格式良好的 URI。实现者**应当**优先采用引用型 URI（`ipfs://`、`ar://`、`https://`）而非体积较大的 `data:` URI，以使更新 gas 有界；在某一版元数据的不可变性重要时，**推荐**采用内容寻址 scheme（`ipfs://`、`ar://`）。
5. 因为 `setAgentURI` 是 Owner 可变权限，消费者**应当**把 URI 视为不可信输入，并**应当**通过 `AgentURIUpdated` 事件呈现 URI 变更历史。

#### 6.6 执行体分发

1. `execute` **必须**在 `msg.sender` 非当前已启用的 Executor 时 revert。
2. 实现**不得**以 `DELEGATECALL` 分发 `execute`。delegatecall 会让 target 获得 Agent 存储槽（执行体集合、所有权槽、份额余额、Agent URI 等）的完全写权限，无论实现者在其之上叠加怎样的高层策略都会失效。默认分发**必须**使用纯 EVM `CALL` 操作码；实现**可以**另起函数名以 `STATICCALL` 提供只读路径，但 `execute` 的规范语义为 `CALL`。
3. 底层调用失败时，Agent **必须**原样抛出其 revert data。
4. `value` **必须**从 Agent 自身余额转出；**不得**要求 Executor 在发起交易时附带以太币。
5. 除 §6.6.1（Executor 检查）、§6.6.2（禁用 `DELEGATECALL`）与 §6.6.7（`isInScope` 门控）之外，协议对 `target` 或 `data` **不施加**任何进一步的规范性约束。实现**可以**叠加更多限制 —— target 白名单、函数选择器过滤、参数过滤、session key、签名策略引擎、外部策略合约、速率限制、断路器等 —— 但超出上述三项要求的任何策略**不属于**本标准的一部分，集成方**不得**将其视为协议保证。评估某 Agent 运行安全性的集成方**应当**检查其具体实现以及 Executor 的运维状况。
6. `Executed` **必须**仅在底层调用成功时 emit。调用失败会 revert（§6.6.3）且不发任何事件；因此集成方无法通过 `Executed` 观察到失败的 Executor 尝试，**必须**依赖被 revert 的交易本身来获得该信号。
7. `execute` 在分发前**必须**调用 `isInScope(target, value, data)`，返回 `false` 则**必须** revert。该 predicate 的逻辑（target 白名单、单资产上限、场景规则、外部策略合约、速率限制……）由实现方定义；标准只固化钩子存在且被强制执行。`isInScope` 是必需 `view`，兼作链下审计查询。
8. `isInScope` 背后的一切（白名单、上限、策略地址）**必须**只能由 Owner（或 Owner 指定的治理）配置——**绝不能**由 Executor 配置。Agent 在一个自己无法放宽的边界内行动。scope 配置的变更**应当**发出实现方定义的事件。

#### 6.7 Owner 角色

1. `owner()` **必须**返回当前有权调用本规范所定义 Owner 级函数（`setExecutor`、`setAgentURI` 以及实现自行添加的更细权限）的地址。
2. 所有权的转让机制 —— 单步、两步、多签签名集轮换、与治理合约绑定、或完全不可转让 —— 不在本标准范围内。实现**可以**采用任何此类机制，也**可以**不提供。支持所有权转让的实现**应当**在每次变更时发出事件以便索引器追踪，具体事件签名由实现者决定。
3. 实现**可以**额外提供暂停机制、按函数粒度的 gating、guardian 角色、针对 Executor 的约束策略或其他治理面。这些不在本标准范围内；见 §7。

#### 6.8 重入（Reentrancy，安全注意事项）

1. `execute` 按设计必然会调用不可信的外部代码，因此重入是本标准引入的最突出风险。实现**应当**保护所有面向用户的状态变更入口 —— `requestMint`、`mint`、`requestRedeem`、`redeem`、`execute` 以及各管理 setter —— 使得恶意外部 target 无法重入它们、在陈旧兑换率或在途请求状态上运作（例如借助重入锁或 checks-effects-interactions 模式）。这是一条安全建议，而非合规必要条件；集成方**应当**在具体实现中核实该 Agent 的重入防护情况（§6.6.5）。
2. 对 view 函数（`isExecutor`、`queryMintStatus`、`queryRedeemStatus`、`exchangeRate`、ERC-20 `balanceOf`）的只读重入并未被禁止；实现者**应当**确保 view 函数返回的会计数值与交易完成后的不变量一致。

### 7. 协议**不**规定的部分

以下内容明确不在本协议规定范围内。实现**可以**在与接口一致的前提下自由决定其行为，**必须**在文档中声明其所做选择：

- `mint` 的份额定价公式与 `redeem` 的"份额→Accept Token"换算公式。
- `mint` 或 `redeem` 是否征收 Owner 费用及其大小。
- 份额是否可转让。合规 Agent **可以**覆盖 ERC-20 的 transfer 以限制、暂停或征税。此类限制**不得**阻断本标准自身要求的生命周期：§6.4.1 的赎回托管拉取、结算时的销毁、§6.3.5 的领取铸造、以及（若支持取消）§6.4.6 的托管份额退回，必须始终可行。
- 结算**内部计算的定价 / 配额 / 接受逻辑**，以及 Executor **何时**选择结算。结算本身现在是标准化的 agent action —— `settleMint` / `settleRedeem`（§6.3 / §6.4）—— 因此*结算是否为标准操作*是固定的，不再由实现者决定。仍由实现者决定的是结算内部计算的定价 / 配额 / 接受公式（多少待结算存款 / 托管份额变为可领取、以何价格），以及 Executor 调用结算的时机 —— 运营方履约、时间延迟、NAV/周期收盘、流动性到位。
- **§6.2 envelope 之外的 reasoning 记录字段与格式** —— `reasoningURI` 所解析 JSON 内部的领域字段（model、prompt、trace、工具调用、评分等）。§6.2 仅固定 envelope（链上 `reasoningHash` 绑定、非空且可解析的 URI、`"schema"` 标记、忽略未知字段），不规定记录内容。
- **请求取消**与**请求过期 / TTL**（含任何 `deadline` 参数）—— requester 能否取回仍处于待结算的已存入 Accept Token / 被托管份额，以及相关的取消/过期事件。
- 多个请求的**批量 / 周期聚合结算**。
- **对结算结果的滑点 / 价格保护。** 领取（`mint` / `redeem`）无条件执行、隐式接受结算价——不带滑点保护，因为份额数 / 赔付在结算时(早于领取)就已固定,claim 阶段的 guard 只会挡住用户领取其应得的部分(无法退还本金)。任何对"结算价格不利"的保护——由结算机制保证的 max-price / min-rate、结算前的取消路径等——均由实现者决定。
- 其他附加退出机制 —— 固定赎回窗口、锁仓期、赎回费分级、最低余额等。
- `exchangeRate()` 是常量（固定价 Agent）还是随时间变化（NAV 型 Agent）。
- Holder 是否在兑换率反映之外另有领取通道（独立分红 / 奖励 / 收益领取通道、定期 Merkle 分发、NFT 凭证等）—— 完全由实现者决定。
- **`isInScope` 所强制的 Scope 策略内容** —— Owner 配置的 Scope 允许哪些 target、函数选择器、参数、单资产上限、速率限制或场景，以及如何表达（白名单、session key、EIP-712 签名预授权、链上策略合约、链下策略执行器等）—— 由实现者决定。**不**属于实现者可选的部分：`execute` 不再是完全无约束的分发原语 —— 标准要求 `isInScope` gate（§6.6.7）、强制 `execute` 执行该 gate（返回 `false` 时 revert）、并要求其配置仅由 Owner 控制、绝不可由 Executor 设置（§6.6.8）。gate 的存在、强制执行与 Owner 控制由标准固定；只有 gate 所编码的策略才由实现者叠加。
- 是否支持多 Executor、Executor 轮换、session key 风格委托、基于签名的元交易执行。
- **任何让中继方代表用户提交请求或 Executor 调用的元交易 / 基于签名的包装层**（例如 EIP-712 签名意图、ERC-2771 forwarder）。本标准只定义每个函数对直接 `msg.sender` 的语义；中继/转发层**可以**在其上叠加，但不属于本标准。
- **Agent 是否可升级及如何升级** —— 代理可升级、合约迁移、或完全不可变 —— 完全由实现者决定。可升级的 Agent **应当**披露升级权限主体及其约束。
- **Owner 级函数是否受 timelock 或延迟约束。** 协议不强制对 `setExecutor`、`setAgentURI` 或其他管理操作施加任何延迟；实现**可以**自行添加。
- §6.5.3 之外的 Agent URI 元数据 schema 扩展字段。
- **Agent 是否可被暂停以及暂停机制** —— 按函数粒度暂停、全局暂停、定时自动恢复、guardian 控制的暂停、或完全不支持暂停 —— 完全由实现者决定。
- **所有权转让机制** —— 单步、两步、可 renounce、与治理合约绑定、或完全不可转让 —— 完全由实现者决定。协议仅要求 `owner()` 报告当前管理地址。
- **Agent 是否及如何提供紧急资产救援（"sweep"）机制** —— 函数签名、可调用者（仅 Owner、Owner + Guardian、双钥）、是否允许触及 Accept Token 或 Share 代币、是否加 timelock / 限额 / 限频、能动用哪些资产 —— 完全由实现者决定。会积累空投、误发、粉尘的 Agent **应当**披露其救援路径；追求完全不可变的 Agent **可以**刻意不提供任何救援路径。
- **Agent 是否提供原子批量执行接口**（常见命名为 `executeBatch` / `multicall`）由实现者决定。合约钱包形态的 Executor 本身就能在一笔自己的交易里连续调用多次 `execute`，实现原子批量；EOA 形态的 Executor 想要批量时，把一个薄 adapter 合约设为 Executor 即可。实现**可以**自行添加批量原语，只要每个子调用仍然通过 §6.6 中 `execute` 所定义的 `onlyExecutor` 检查与 `DELEGATECALL` 禁令，仍属合规。

## 设计理由（Rationale）

**为什么结算是一次经推理的 agent 动作——这是本标准主体性的试金石。** 一个只会被动记账的合约是容器；一个对每笔出资与退出作出显式决定、且必须为该决定署名留证的合约，是行动者。把 agent 的反应（`settleMint` / `settleRedeem`）做成显式、标准化的操作——而非一个不透明的实现者步骤——使这项经济决策变得清晰可读、可归因、可索引。由于结算金额是在调用内部由合约逻辑计算的，而非由调用方提供，Executor 无法铸造或支付任意金额。

**为什么采用两阶段"申请→领取"生命周期，而非同步铸造/赎回。** Agent 的资金通常已部署到外部协议，因此一笔存款未必能在提交的同一笔交易里定价，一笔赎回也未必能在同一笔交易里支付。两阶段流程让发起人先提交、待 Agent 结算后（为存款定价、或腾出流动性）再领取——这正是协议的延迟流动性机制。即便是即时型 Agent，也通过一笔独立、迅捷的 Executor `settleMint` / `settleRedeem` 交易来结算，而非在 `requestMint` 内部结算——结算永远是一次显式的、经推理的 agent 动作（见下文）。

**为什么不提供委托或 operator 模型。** 本标准把逐发起人的记账收敛到单一地址（开启请求的那个地址），并把每一次领取都付给这个应得方地址。完整的委托模型——即第三方可以替用户开启请求、或把领取改道给另一个收款人——被刻意省去以保持接口最小化。本标准**确实**允许的、且无需任何授权的是无许可领取（见下一条），它覆盖了常见的"让别人替我完成领取"需求；被省去的是改道——把领取付给应得方以外的收款人——因为那需要应得方授权。

**为什么 `mint` / `redeem` 带一个 `address` 参数、且任何人都可调用。** 两阶段设计强制了第二笔交易来领取已结算的份额/代币。把这次领取做成无许可的——`mint(user)` / `redeem(user)` 任何地址都能调用、但永远付给应得方 `user`——让 keeper、dApp 或 Agent 运营方可以替用户完成领取并代付 gas，且无需任何授权：因为赔付只能流向应得方，任意调用者无利可图。开启请求仍仅限本人，因为 `requestMint` / `requestRedeem` 动用的是调用者自己的资金或份额，没有授权就无法代他人开启。

**为什么 `mint` / `redeem` 不带滑点参数。** 份额数（mint）与赔付（redeem）在结算时固定，而结算发生在领取之前。因此领取阶段的滑点 guard 只能挡住发起人领取其已应得的部分——无法退还原始本金。对"结算价不利"的保护（由结算机制保证的 max-price/min-rate、或结算前的取消路径）才是这类 guard 有意义的位置，并交由实现者决定（§7）。

**为什么 `exchangeRate()` 是估值参考而非成交预测。** 把估值与成交分离，使固定价与 NAV 型 Agent 共用一套接口，也让工具能估值持仓而不暗示一笔 mint/redeem 会按该率成交。实际成交结果由 `queryMintStatus` / `queryRedeemStatus` 给出。

**为什么重入防护是建议而非合规要求。** 本标准固化的是接口而非实现技术；强制某种具体的重入防护机制会过度约束实现者。该风险真实存在（§6.8），因此以强烈建议的形式记录、并在[安全考量](#安全考量security-considerations)中提示，同时引导集成方核实每个 Agent 的具体防护情况。（是否恢复为合规级 MUST，是留给标准编者的开放设计问题。）

**为什么采用单一不可变 Accept Token。** 在部署时固定计价单位，使份额定价与赎回无歧义，并让每个 Agent 都能通过一条清晰路径被估值与退出。

**为什么 `execute` 是一个受三条不变量约束的薄原语。** 沿袭"策略与接口分离"的思路：标准保证 `onlyExecutor` 检查、`DELEGATECALL` 禁令与强制的 `isInScope` 门（§6.6.7），任何进一步的约束层（白名单、selector 过滤、session key、策略合约）都由实现者在其上叠加。这让行为层本身保持标准，而把其安全边界——包括具体的 Scope 策略——留给每个 Agent。
**为什么推理是一个哈希加一个可解析的 URI、且当下即公布。** 把推理内容的 `keccak256` 锚定在链上，使记录具备防篡改性；要求 `reasoningURI` 非空且可立即解析，使其保持可发现。延迟揭示并无必要：内容寻址方案（`ipfs://`、`ar://`）让 agent 可以在公布之前先承诺 CID，因此"先私有后公开"的推理无需任何协议机制。

**为什么 `execute` 强制一个 `isInScope` 钩子，而非固定的 scope 形态。** 标准化的是执行点（每一次花费都经过一个谓词），而非策略（谓词允许什么）——这在不锁死 scope 表示的前提下给出了约束力。由于 `isInScope` 是一个必需的 `view`，集成方可以免费获得边界可审计性。

**为什么 Scope 仅限 Owner，且结算从不在 `requestMint` 内部发生。** 如果 Executor 能自行放宽其 Scope，边界就形同虚设，因此 Scope 配置仅限 Owner。而且每一次结算都必须是一次可归因的、经推理的 agent 动作，因此本标准不允许在 `requestMint` 内部结算——结算始终是一次独立的 `settleMint` / `settleRedeem` 调用。

## 向后兼容性（Backwards Compatibility）

FAT 是新标准，无向后兼容约束。

它与下列标准正交组合：

- **ERC-20** — 份额代币必需。
- **ERC-165** — 实现**必须**通过 ERC-165（`supportsInterface`）声明其对 FAT 的支持，interface ID 为 §4 各函数选择器的 XOR，以便索引器、钱包与组合合约获得协议层的可发现性保证。本规范离开 Draft 状态时会固化该 ID。

Agent **不应当**以"只实现接口子集"的方式来"部分合规" FAT；部分合规在本标准中的定义就是不合规。

## 安全考量（Security Considerations）

本段汇总一个 FAT Agent 固有的风险，供实现者与集成方权衡与披露。除非复述 §6 的某条规范性要求，本段均为提示性内容：描述的是考量与建议披露，而非新增的合规要求。

**Executor 是被高度信任的角色，仅受其 Scope 约束。** 在协议层，`execute` 受 Executor 检查（§6.6.1）、`DELEGATECALL` 禁令（§6.6.2）与 Owner 设定的 `isInScope` 门（§6.6.7）约束。在其 Scope 内，一个被启用的 Executor 能动用 Agent 持有的每一项资产、并以其名义签发任意授权。集成方**必须**把"是 FAT Agent"理解为对 Executor 在该 Scope 内能做什么不提供任何保证，并**应当**在信任某 Agent 前评估其具体的 Scope 策略（白名单、selector/参数过滤、session key、策略合约）、谁能改它（§6.6.8）以及 Executor 的运维状况（密钥托管、自动化程度）。

**角色集中与内部自我交易。** §3 的各角色可以集中由一个地址持有。把 Owner 与 Executor 集中在一个密钥，会赋予它对 Agent 资产、执行体集合与元数据的单方面控制——对任何外部 Holder 而言都是信任最大化的配置。另一方面，同时持有份额或开启请求的 Executor / Owner，有动机利用其特权（由 `execute` 驱动的 NAV 变动、或对结算时机的裁量权）让自身头寸优于其他 Holder（这是下文抢跑与结算时机风险的一个内部人特例）。面向外部资金的 Agent **应当**分离这些特权角色（例如多签 Owner、独立 Executor、对管理操作加 timelock），并**应当**在 Agent URI 元数据中披露这种分离——或其缺失。

**重入。** `execute` 会调用不可信外部代码，因此重入是本标准引入的最突出风险。§6.8 建议保护所有面向用户的状态变更入口（如借助重入锁或 checks-effects-interactions），并提示对 view 函数的只读重入。由于 §6.8 是建议而非合规要求，集成方**应当**在具体实现中核实该 Agent 的重入防护情况；在这一点上的错误假设，历史上曾在 DeFi 中造成巨额损失。

**抢跑结算（Settlement Front-Running）。** 当 Agent 以聚合方式结算（例如以单一批次/NAV 价格）时，掌握即将结算价格的参与者可以抢跑：在利好 NAV 更新前 `requestMint` 以陈旧价捕获上行，或在利空更新前 `requestRedeem` 以陈旧价退出——两种情形都损害存量 Holder。实现者**应当**以下列措施之一缓解：(1) 结算价在 commit-reveal / 链上 oracle / 时间锁定后才可见；(2) 请求窗口与结算窗口隔离（请求截止早于价格确定）；(3) 逐请求即时结算——Executor 在各自的 `settleMint`/`settleRedeem` 调用中结算每一笔请求，不设聚合窗口。

**结算时机的中心化。** §6.3.3 / §6.4.3 把结算触发交给实现者。若该触发权集中在 Owner 或 Executor，该主体便可选择*何时*结算，从而在 minter 与 redeemer 之间转移价值（在低 NAV 时结算赎回、高 NAV 时结算铸造，或反之）——实质上是一条隐性 fee 通道。Agent **应当**在 Agent URI 元数据中披露结算触发机制（自动 / 周期性 / Owner 手动 / oracle 触发等）及其择时风险。

**隐式接受结算价。** 因为领取（`mint` / `redeem`）不带滑点 guard，Requester 接受的是 Agent 在结算时固定的价格，而该决定是在请求提交之后做出的（§6.3、§6.4、§7）。这与同步、带滑点保护的兑换是不同的信任模型：在提交请求的时刻，Requester 已在信任 Agent 的结算机制。任何对"结算价不利"的保护（结算时保证的 max-price/min-rate、或结算前的取消路径）均由实现者决定。

**卡死的待结算请求。** 当余额处于待结算时，发起人已存入的 Accept Token（铸造）留在 Agent 中，被托管的份额（赎回）被持有但尚未销毁。若结算始终不触发——Owner 弃管 Agent、Executor 密钥丢失、或合约被永久禁用（brick）——这些余额可能在无领取路径的情况下被卡死，而对一笔待结算的铸造，发起人甚至还不是 Holder。Agent **应当**要么为 Requester 提供取回仍处于待结算的存款/托管的路径，要么在 Agent URI 元数据中披露"请求一旦提交即不可逆"及其边界（如最长结算时限）。（是否把这条"取回或披露"规则升为合规要求，是留给标准编者的开放设计问题。）

**Agent URI 可变且不可信。** `setAgentURI` 是 Owner 可控的（§6.5.5），因此元数据——包括上文提及的任何披露——随时可变。消费者**应当**把 URI 视为不可信输入，并通过 `AgentURIUpdated` 呈现其变更历史。

**Accept Token 假设。** 精确数量记账（§6.3.1）假定标准 ERC-20。fee-on-transfer 与 rebasing 的 Accept Token 会破坏该假设；Agent 要么以文档化的对账方式支持它们，要么在文档中声明不支持（§6.3.1）。

**Reasoning 是描述性的，并非被强制执行。** `reasoningHash`/`reasoningURI` 只证明 Executor 提交了一条 reasoning 记录且未被篡改——并不证明该 reasoning 合理、或该动作确实由它推导而来。集成方应把 reasoning 视为审计线索，而非保证。

**Scope 的收紧程度取决于 `isInScope`。** 过于宽松的谓词只能给出很弱的边界。审计者**应当**在预期的目标集合上逐一检验 `isInScope`，并核查谁能变更 Scope 配置（**必须**仅 Owner 可变更，§6.6.8），再去信任某 Agent 的支出边界。

**Reasoning 可用性。** 由于不支持延迟披露（deferred reveal），一个无法解析的 `reasoningURI`（死链、未 pin 的内容）会破坏事后审计，即便链上的 `reasoningHash` 仍然成立。**推荐**使用内容寻址、已 pin 的存储（`ipfs://`、`ar://`）。

## 版权（Copyright）

以 [CC0-1.0](https://creativecommons.org/publicdomain/zero/1.0/) 放弃版权及相关权利。
