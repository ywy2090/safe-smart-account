// SPDX-License-Identifier: LGPL-3.0-only
/* solhint-disable one-contract-per-file */
pragma solidity >=0.7.0 <0.9.0;
import {SelfAuthorized} from "./../common/SelfAuthorized.sol";
import {IERC165} from "./../interfaces/IERC165.sol";
import {IModuleManager} from "./../interfaces/IModuleManager.sol";
import {Enum} from "./../interfaces/Enum.sol";
// solhint-disable-next-line no-unused-import
import {MODULE_GUARD_STORAGE_SLOT} from "./../libraries/SafeStorage.sol";
import {Executor} from "./Executor.sol";

/**
 * @title IModuleGuard Interface
 */
interface IModuleGuard is IERC165 {
    /**
     * @notice Checks the module transaction details.
     * @dev The function needs to implement module transaction validation logic.
     * @param to The address to which the transaction is intended.
     * @param value The value of the transaction in Wei.
     * @param data The transaction data.
     * @param operation Operation type (0 for `CALL`, 1 for `DELEGATECALL`) of the module transaction.
     * @param module The module involved in the transaction.
     * @return moduleTxHash A guard-specific module transaction hash. This value is passed to the matching {checkAfterModuleExecution} call.
     */
    function checkModuleTransaction(
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation,
        address module
    ) external returns (bytes32 moduleTxHash);

    /**
     * @notice Checks after execution of module transaction.
     * @dev The function needs to implement a check after the execution of the module transaction.
     * @param txHash The guard-specific module transaction hash returned from the matching {checkModuleTransaction} call.
     * @param success The status of the module transaction execution.
     */
    function checkAfterModuleExecution(bytes32 txHash, bool success) external;
}

/**
 * @title Base Module Guard
 */
abstract contract BaseModuleGuard is IModuleGuard {
    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(bytes4 interfaceId) external view virtual override returns (bool) {
        return
            interfaceId == type(IModuleGuard).interfaceId || // 0x58401ed8
            interfaceId == type(IERC165).interfaceId; // 0x01ffc9a7
    }
}

/**
 * @title Module Manager
 * @notice 管理 Safe 的模块：模块可由 owner 添加，并通过 execTransactionFromModule 以 Safe 身份执行任意调用。
 * @dev 模块拥有与 Safe 等同的调用权限，仅应添加受信任且审计过的模块；恶意模块可完全控制 Safe。
 *      支持可选的 Module Guard，在模块执行前后做检查。模块列表用链表存储，与 OwnerManager 类似。
 * @author Stefan George - @Georgi87
 * @author Richard Meissner - @rmeissner
 */
abstract contract ModuleManager is SelfAuthorized, Executor, IModuleManager {
    /**
     * @dev 模块链表哨兵：modules[SENTINEL_MODULES] 为第一个模块，末项指回 SENTINEL_MODULES。
     *      `SENTINEL_MODULES` is used to traverse {modules}, such that:
     *      1. `modules[SENTINEL_MODULES]` contains the first module
     *      2. `modules[last_module]` points back to `SENTINEL_MODULES`
     */
    address internal constant SENTINEL_MODULES = address(0x1);

    /**
     * @dev The linked list of modules, where `modules[module]` points to the next in the list.
     *      A mapping is used to allow for `O(1)` inclusion checks.
     */
    mapping(address => address) internal modules;

    /**
     * @notice 初始化模块存储；可选地 delegatecall 到 to 执行 data 做进一步设置（如批量 enable 模块）。
     * @param to 若非 0，则对 to 做 DelegateCall(data)，用于 setup 时一次性配置模块。
     * @param data 传给 to 的 calldata。
     */
    function setupModules(address to, bytes memory data) internal {
        if (modules[SENTINEL_MODULES] != address(0)) revertWithError("GS100"); // 已初始化
        modules[SENTINEL_MODULES] = SENTINEL_MODULES;
        if (to != address(0)) {
            if (!isContract(to)) revertWithError("GS002");
            if (!execute(to, 0, data, Enum.Operation.DelegateCall, type(uint256).max)) revertWithError("GS000");
        }
    }

    /**
     * @notice 模块交易执行前：触发钩子、校验调用方为已启用模块、若设置了 Module Guard 则执行前置检查。
     * @return guard 当前设置的 Module Guard 地址（可为 0）。
     * @return guardHash Guard 返回的 moduleTxHash，供 postModuleExecution 使用。
     */
    function preModuleExecution(
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation
    ) internal returns (address guard, bytes32 guardHash) {
        onBeforeExecTransactionFromModule(to, value, data, operation);
        guard = getModuleGuard();

        if (msg.sender == SENTINEL_MODULES || modules[msg.sender] == address(0)) revertWithError("GS104"); // 仅已启用模块可调

        if (guard != address(0)) {
            guardHash = IModuleGuard(guard).checkModuleTransaction(to, value, data, operation, msg.sender);
        }
    }

    /**
     * @notice Runs post-execution checks for module transactions if a guard is enabled.
     * @dev Emits event based on module transaction success.
     * @param guard Guard to be used for checking.
     * @param guardHash Hash returned from the guard during the pre-execution check.
     * @param success Boolean flag indicating if the call succeeded.
     */
    function postModuleExecution(address guard, bytes32 guardHash, bool success) internal {
        if (guard != address(0)) {
            IModuleGuard(guard).checkAfterModuleExecution(guardHash, success);
        }
        if (success) emit ExecutionFromModuleSuccess(msg.sender);
        else emit ExecutionFromModuleFailure(msg.sender);
    }

    /**
     * @inheritdoc IModuleManager
     */
    function enableModule(address module) public override authorized {
        // Module address cannot be null or sentinel.
        if (module == address(0) || module == SENTINEL_MODULES) revertWithError("GS101");
        // Module cannot be added twice.
        if (modules[module] != address(0)) revertWithError("GS102");
        modules[module] = modules[SENTINEL_MODULES];
        modules[SENTINEL_MODULES] = module;
        emit EnabledModule(module);
    }

    /**
     * @inheritdoc IModuleManager
     */
    function disableModule(address prevModule, address module) public override authorized {
        // Validate module address and check that it corresponds to a module index.
        if (module == address(0) || module == SENTINEL_MODULES) revertWithError("GS101");
        if (modules[prevModule] != module) revertWithError("GS103");
        modules[prevModule] = modules[module];
        modules[module] = address(0);
        emit DisabledModule(module);
    }

    /**
     * @inheritdoc IModuleManager
     */
    function execTransactionFromModule(
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation
    ) external override returns (bool success) {
        (address guard, bytes32 guardHash) = preModuleExecution(to, value, data, operation);
        success = execute(to, value, data, operation, type(uint256).max);
        postModuleExecution(guard, guardHash, success);
    }

    /**
     * @inheritdoc IModuleManager
     */
    function execTransactionFromModuleReturnData(
        address to,
        uint256 value,
        bytes memory data,
        Enum.Operation operation
    ) external override returns (bool success, bytes memory returnData) {
        (address guard, bytes32 guardHash) = preModuleExecution(to, value, data, operation);
        success = execute(to, value, data, operation, type(uint256).max);
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            // Load free memory location.
            returnData := mload(0x40)
            // We allocate memory for the return data by setting the free memory location to
            // current free memory location plus the return data size with an additional 32
            // bytes for storing the length of the return data.
            mstore(0x40, add(returnData, add(returndatasize(), 0x20)))
            // Store the size.
            mstore(returnData, returndatasize())
            // Store the data.
            returndatacopy(add(returnData, 0x20), 0, returndatasize())
        }
        /* solhint-enable no-inline-assembly */
        postModuleExecution(guard, guardHash, success);
    }

    /**
     * @inheritdoc IModuleManager
     */
    function isModuleEnabled(address module) public view override returns (bool) {
        return SENTINEL_MODULES != module && modules[module] != address(0);
    }

    /**
     * @inheritdoc IModuleManager
     */
    function getModulesPaginated(address start, uint256 pageSize) external view override returns (address[] memory array, address next) {
        if (start != SENTINEL_MODULES && !isModuleEnabled(start)) revertWithError("GS105");
        if (pageSize == 0) revertWithError("GS106");
        // Init array with max page size.
        array = new address[](pageSize);

        // Populate return array.
        uint256 moduleCount = 0;
        next = modules[start];
        while (next != address(0) && next != SENTINEL_MODULES && moduleCount < pageSize) {
            array[moduleCount] = next;
            next = modules[next];
            ++moduleCount;
        }

        // Because of the argument validation, we can assume that the loop will always iterate over the valid module list values
        // and the `next` variable will either be an enabled module or a sentinel address (signalling the end).
        //
        // If we haven't reached the end inside the loop, we need to set the next pointer to the last element of the modules array
        // because the `next` variable (which is a module by itself) acting as a pointer to the start of the next page is neither
        // included to the current page, nor will it be included in the next one if you pass it as a start.
        if (next != SENTINEL_MODULES) {
            next = array[moduleCount - 1];
        }
        // Set the correct size of the returned array.
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            mstore(array, moduleCount)
        }
        /* solhint-enable no-inline-assembly */
    }

    /**
     * @notice Returns true if `account` appears to be a contract.
     * @dev This function will return false if invoked during the constructor of a contract,
     *      as the code is not created until after the constructor finishes.
     * @param account The address being queried.
     */
    function isContract(address account) internal view returns (bool) {
        uint256 size;
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            size := extcodesize(account)
        }
        /* solhint-enable no-inline-assembly */
        return size > 0;
    }

    /**
     * @inheritdoc IModuleManager
     */
    function setModuleGuard(address moduleGuard) external override authorized {
        if (moduleGuard != address(0) && !IModuleGuard(moduleGuard).supportsInterface(type(IModuleGuard).interfaceId))
            revertWithError("GS301");

        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            sstore(MODULE_GUARD_STORAGE_SLOT, moduleGuard)
        }
        /* solhint-enable no-inline-assembly */
        emit ChangedModuleGuard(moduleGuard);
    }

    /**
     * @dev Internal method to retrieve the current module guard.
     * @return moduleGuard The address of the module guard.
     */
    function getModuleGuard() internal view returns (address moduleGuard) {
        /* solhint-disable no-inline-assembly */
        /// @solidity memory-safe-assembly
        assembly {
            moduleGuard := sload(MODULE_GUARD_STORAGE_SLOT)
        }
        /* solhint-enable no-inline-assembly */
    }

    /**
     * @notice A hook that gets called before execution of {execTransactionFromModule*} methods.
     * @param to Destination address of module transaction.
     * @param value Native token value of module transaction.
     * @param data Data payload of module transaction.
     * @param operation Operation type of module transaction.
     */
    function onBeforeExecTransactionFromModule(address to, uint256 value, bytes memory data, Enum.Operation operation) internal virtual {}
}
