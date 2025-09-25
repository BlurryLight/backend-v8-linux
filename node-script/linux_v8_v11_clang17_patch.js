const fs = require('fs');
const path = require('path')

const v8_path = path.resolve(process.argv[2]);

function patch_config_compiler_build_gn() {
    const filepath = path.join(v8_path, 'build/config/compiler/BUILD.gn')
    let context = fs.readFileSync(filepath, 'utf-8');
    const libcxx_start = context.indexOf('cflags_cc += [ "-stdlib=libc++" ]');
    if (libcxx_start > 0) {
      console.log("libcxx already patched, skip.");
      return;
    }
    
    /*
      # Clang-specific compiler flags setup.
  # ------------------------------------
  if (is_clang) {
    cflags += [ "-fcolor-diagnostics" ]
    cflags_cc += [ "-stdlib=libc++" ]  //  Patched LIne
    cflags_cc += [ "-D_LIBCPP_AVAILABILITY_HAS_NO_VERBOSE_ABORT=1" ] // Patched Line

    # Enable -fmerge-all-constants. This used to be the default in clang
    # for over a decade. It makes clang non-conforming, but is fairly safe
    # in practice and saves some binary size. We might want to consider
    # disabling this (https://bugs.llvm.org/show_bug.cgi?id=18538#c13),
    # but for now it looks like our build might rely on it
    # (https://crbug.com/829795).
    cflags += [ "-fmerge-all-constants" ]
  }

    */
       // 查找 if (is_clang) { 的位置
    const clang_if_start = context.indexOf('if (is_clang) {');
    if (clang_if_start < 0) {
      console.error('Cannot find "if (is_clang) {" block.');
      return;
    }

    // 找到插入点（即 if (is_clang) { 后的下一行）
    const insert_pos = context.indexOf('\n', clang_if_start) + 1;

    // 需要插入的 patch 行
    const libcxx_patch = `    cflags_cc += [ "-stdlib=libc++" ]
    cflags_cc += [ "-D_LIBCPP_AVAILABILITY_HAS_NO_VERBOSE_ABORT=1" ]
`;

    // 插入 patch
    const new_context = context.slice(0, insert_pos) + libcxx_patch + context.slice(insert_pos);

    new_context.replace("-Wl,--color-diagnostics", "-Wl,--color-diagnostics,-stdlib=libc++");

    fs.writeFileSync(filepath, new_context);
    console.log('Patch applied.');
}

(function() {
    patch_config_compiler_build_gn();
})();
