declare namespace __AdaptedExports {
  /**
   * calc_ts/scratch
   * @param need `u32`
   * @returns `u32`
   */
  export function scratch(need: number): number;
  /**
   * calc_ts/host_arena
   * @returns `u32`
   */
  export function host_arena(): number;
  /**
   * calc_ts/run
   * @param ptr `u32`
   * @param len `u32`
   * @returns `u64`
   */
  export function run(ptr: number, len: number): bigint;
}
/** Instantiates the compiled WebAssembly module with the given imports. */
export declare function instantiate(module: WebAssembly.Module, imports: {
  env: unknown,
}): Promise<typeof __AdaptedExports>;
