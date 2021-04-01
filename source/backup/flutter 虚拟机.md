##### 4.1.1.1 DartVMRef::Create 创建Dart虚拟机

```cpp
DartVMRef DartVMRef::Create(Settings settings,
                            fml::RefPtr<DartSnapshot> vm_snapshot,
                            fml::RefPtr<DartSnapshot> isolate_snapshot,
                            fml::RefPtr<DartSnapshot> shared_snapshot) {
  std::scoped_lock lifecycle_lock(gVMMutex);

  if (auto vm = gVM.lock()) {

    return DartVMRef{std::move(vm)};
  }

  std::scoped_lock dependents_lock(gVMDependentsMutex);

  gVMData.reset();
  gVMServiceProtocol.reset();
  gVMIsolateNameServer.reset();
  gVM.reset();

  // If there is no VM in the process. Initialize one, hold the weak reference
  // and pass a strong reference to the caller.
  auto isolate_name_server = std::make_shared<IsolateNameServer>();
  auto vm = DartVM::Create(std::move(settings),          //
                           std::move(vm_snapshot),       //
                           std::move(isolate_snapshot),  //
                           std::move(shared_snapshot),   //
                           isolate_name_server           //
  );

  if (!vm) {
    FML_LOG(ERROR) << "Could not create Dart VM instance.";
    return {nullptr};
  }

  gVMData = vm->GetVMData();
  gVMServiceProtocol = vm->GetServiceProtocol();
  gVMIsolateNameServer = isolate_name_server;
  gVM = vm;

  if (settings.leak_vm) {
    gVMLeak = new std::shared_ptr<DartVM>(vm);
  }

  return DartVMRef{std::move(vm)};
}
```

- 1.一个进程只允许存在一个dart虚拟机，且对象为DartVM::Create生成的DartVMRef。

```cpp
std::shared_ptr<DartVM> DartVM::Create(
    Settings settings,
    fml::RefPtr<DartSnapshot> vm_snapshot,
    fml::RefPtr<DartSnapshot> isolate_snapshot,
    fml::RefPtr<DartSnapshot> shared_snapshot,
    std::shared_ptr<IsolateNameServer> isolate_name_server) {
  auto vm_data = DartVMData::Create(settings,                     //
                                    std::move(vm_snapshot),       //
                                    std::move(isolate_snapshot),  //
                                    std::move(shared_snapshot)    //
  );

  if (!vm_data) {
    FML_LOG(ERROR) << "Could not setup VM data to bootstrap the VM from.";
    return {};
  }

  // Note: std::make_shared unviable due to hidden constructor.
  return std::shared_ptr<DartVM>(
      new DartVM(std::move(vm_data), std::move(isolate_name_server)));
}
```

##### 4.1.1.1.2 DartVM::DartVM

```cpp
DartVM::DartVM(std::shared_ptr<const DartVMData> vm_data,
               std::shared_ptr<IsolateNameServer> isolate_name_server)
    : settings_(vm_data->GetSettings()),
      concurrent_message_loop_(fml::ConcurrentMessageLoop::Create()),
      skia_concurrent_executor_(
          [runner = concurrent_message_loop_->GetTaskRunner()](
              fml::closure work) { runner->PostTask(work); }),
      vm_data_(vm_data),
      isolate_name_server_(std::move(isolate_name_server)),
      service_protocol_(std::make_shared<ServiceProtocol>()) {
  TRACE_EVENT0("flutter", "DartVMInitializer");

  gVMLaunchCount++;

  // Setting the executor is not thread safe but Dart VM initialization is. So
  // this call is thread-safe.
  SkExecutor::SetDefault(&skia_concurrent_executor_);

  FML_DCHECK(vm_data_);
  FML_DCHECK(isolate_name_server_);
  FML_DCHECK(service_protocol_);

  FML_DLOG(INFO) << "Attempting Dart VM launch for mode: "
                 << (IsRunningPrecompiledCode() ? "AOT" : "Interpreter");

  {
    TRACE_EVENT0("flutter", "dart::bin::BootstrapDartIo");
    dart::bin::BootstrapDartIo();

    if (!settings_.temp_directory_path.empty()) {
      dart::bin::SetSystemTempDirectory(settings_.temp_directory_path.c_str());
    }
  }

  std::vector<const char*> args;

  // Instruct the VM to ignore unrecognized flags.
  // There is a lot of diversity in a lot of combinations when it
  // comes to the arguments the VM supports. And, if the VM comes across a flag
  // it does not recognize, it exits immediately.
  args.push_back("--ignore-unrecognized-flags");

  for (auto* const profiler_flag :
       ProfilingFlags(settings_.enable_dart_profiling)) {
    args.push_back(profiler_flag);
  }

  PushBackAll(&args, kDartLanguageArgs, fml::size(kDartLanguageArgs));

  if (IsRunningPrecompiledCode()) {
    PushBackAll(&args, kDartPrecompilationArgs,
                fml::size(kDartPrecompilationArgs));
  }

  // Enable Dart assertions if we are not running precompiled code. We run non-
  // precompiled code only in the debug product mode.
  bool enable_asserts = !settings_.disable_dart_asserts;

#if !OS_FUCHSIA
  if (IsRunningPrecompiledCode()) {
    enable_asserts = false;
  }
#endif  // !OS_FUCHSIA

#if (FLUTTER_RUNTIME_MODE == FLUTTER_RUNTIME_MODE_DEBUG)
#if !OS_IOS || TARGET_OS_SIMULATOR
  // Debug mode uses the JIT, disable code page write protection to avoid
  // memory page protection changes before and after every compilation.
  PushBackAll(&args, kDartWriteProtectCodeArgs,
              fml::size(kDartWriteProtectCodeArgs));
#else
  EnsureDebuggedIOS(settings_);
#if TARGET_CPU_ARM
  // Tell Dart in JIT mode to not use integer division on armv7
  // Ideally, this would be detected at runtime by Dart.
  // TODO(dnfield): Remove this code
  // https://github.com/dart-lang/sdk/issues/24743
  PushBackAll(&args, kDartDisableIntegerDivisionArgs,
              fml::size(kDartDisableIntegerDivisionArgs));
#endif  // TARGET_CPU_ARM
#endif  // !OS_IOS || TARGET_OS_SIMULATOR
#endif  // (FLUTTER_RUNTIME_MODE == FLUTTER_RUNTIME_MODE_DEBUG)

  if (enable_asserts) {
    PushBackAll(&args, kDartAssertArgs, fml::size(kDartAssertArgs));
  }

  if (settings_.start_paused) {
    PushBackAll(&args, kDartStartPausedArgs, fml::size(kDartStartPausedArgs));
  }

  if (settings_.disable_service_auth_codes) {
    PushBackAll(&args, kDartDisableServiceAuthCodesArgs,
                fml::size(kDartDisableServiceAuthCodesArgs));
  }

  if (settings_.endless_trace_buffer || settings_.trace_startup) {
    // If we are tracing startup, make sure the trace buffer is endless so we
    // don't lose early traces.
    PushBackAll(&args, kDartEndlessTraceBufferArgs,
                fml::size(kDartEndlessTraceBufferArgs));
  }

  if (settings_.trace_systrace) {
    PushBackAll(&args, kDartSystraceTraceBufferArgs,
                fml::size(kDartSystraceTraceBufferArgs));
    PushBackAll(&args, kDartTraceStreamsArgs, fml::size(kDartTraceStreamsArgs));
  }

  if (settings_.trace_startup) {
    PushBackAll(&args, kDartTraceStartupArgs, fml::size(kDartTraceStartupArgs));
  }

#if defined(OS_FUCHSIA)
  PushBackAll(&args, kDartFuchsiaTraceArgs, fml::size(kDartFuchsiaTraceArgs));
  PushBackAll(&args, kDartTraceStreamsArgs, fml::size(kDartTraceStreamsArgs));
#endif

  for (size_t i = 0; i < settings_.dart_flags.size(); i++)
    args.push_back(settings_.dart_flags[i].c_str());

  char* flags_error = Dart_SetVMFlags(args.size(), args.data());
  if (flags_error) {
    FML_LOG(FATAL) << "Error while setting Dart VM flags: " << flags_error;
    ::free(flags_error);
  }

  DartUI::InitForGlobal();

  {
    TRACE_EVENT0("flutter", "Dart_Initialize");
    Dart_InitializeParams params = {};
    params.version = DART_INITIALIZE_PARAMS_CURRENT_VERSION;
    params.vm_snapshot_data = vm_data_->GetVMSnapshot().GetDataMapping();
    params.vm_snapshot_instructions =
        vm_data_->GetVMSnapshot().GetInstructionsMapping();
    params.create_group = reinterpret_cast<decltype(params.create_group)>(
        DartIsolate::DartIsolateGroupCreateCallback);
    params.shutdown_isolate =
        reinterpret_cast<decltype(params.shutdown_isolate)>(
            DartIsolate::DartIsolateShutdownCallback);
    params.cleanup_group = reinterpret_cast<decltype(params.cleanup_group)>(
        DartIsolate::DartIsolateGroupCleanupCallback);
    params.thread_exit = ThreadExitCallback;
    params.get_service_assets = GetVMServiceAssetsArchiveCallback;
    params.entropy_source = dart::bin::GetEntropy;
    char* init_error = Dart_Initialize(&params);
    if (init_error) {
      FML_LOG(FATAL) << "Error while initializing the Dart VM: " << init_error;
      ::free(init_error);
    }

    if (engine_main_enter_ts != 0) {
      Dart_TimelineEvent("FlutterEngineMainEnter",  // label
                         engine_main_enter_ts,      // timestamp0
                         engine_main_enter_ts,      // timestamp1_or_async_id
                         Dart_Timeline_Event_Duration,  // event type
                         0,                             // argument_count
                         nullptr,                       // argument_names
                         nullptr                        // argument_values
      );
    }
  }

  Dart_SetFileModifiedCallback(&DartFileModifiedCallback);

  // Allow streaming of stdout and stderr by the Dart vm.
  Dart_SetServiceStreamCallbacks(&ServiceStreamListenCallback,
                                 &ServiceStreamCancelCallback);

  Dart_SetEmbedderInformationCallback(&EmbedderInformationCallback);

  if (settings_.dart_library_sources_kernel != nullptr) {
    std::unique_ptr<fml::Mapping> dart_library_sources =
        settings_.dart_library_sources_kernel();
    // Set sources for dart:* libraries for debugging.
    Dart_SetDartLibrarySourcesKernel(dart_library_sources->GetMapping(),
                                     dart_library_sources->GetSize());
  }

  FML_DLOG(INFO) << "New Dart VM instance created. Instance count: "
                 << gVMLaunchCount;
}
```