declare namespace __AdaptedExports {
  /**
   * json_tool/run
   * @param ptr `u32`
   * @param len `u32`
   * @returns `u64`
   */
  export function run(ptr: number, len: number): bigint;
  /**
   * lib/scratch
   * @param need `u32`
   * @returns `u32`
   */
  export function scratch(need: number): number;
  /**
   * lib/host_arena
   * @returns `u32`
   */
  export function host_arena(): number;
}
/** Instantiates the compiled WebAssembly module with the given imports. */
export declare function instantiate(module: WebAssembly.Module, imports: {
  env: unknown,
}): Promise<typeof __AdaptedExports>;
