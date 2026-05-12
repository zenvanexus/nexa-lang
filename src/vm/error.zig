pub const VmError = error{
    LuaError,
    TypeMismatch,
    StackOverflow,
    NotCallable,
    OutOfMemory,
};
