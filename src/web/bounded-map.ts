/** Map values with a fixed maximum number of operations in flight. */
export async function mapWithConcurrency<T, R>(
  values: readonly T[],
  concurrency: number,
  mapper: (value: T, index: number) => Promise<R> | R,
): Promise<R[]> {
  if (!Number.isInteger(concurrency) || concurrency < 1) {
    throw new RangeError("concurrency must be a positive integer");
  }

  const results = new Array<R>(values.length);
  let nextIndex = 0;
  const workerCount = Math.min(concurrency, values.length);
  await Promise.all(Array.from({ length: workerCount }, async () => {
    while (true) {
      const index = nextIndex++;
      if (index >= values.length) return;
      results[index] = await mapper(values[index]!, index);
    }
  }));
  return results;
}
