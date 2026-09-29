import type { Matrix } from "./provider.ts";

// Fixed anchor at index 0; deterministic time-first, distance-second nearest neighbour.
// Directed 2-opt includes the cost of reversing every internal edge, not just the boundary edges.
const better = (a: number[], b: number[]) => a[0] < b[0] - 1e-9 ||
  (Math.abs(a[0] - b[0]) <= 1e-9 && a[1] < b[1] - 1e-9);
export function drivingOrder(matrix: Matrix, closed: boolean): number[] {
  const remaining = new Set(matrix.times.map((_, i) => i).slice(1)), order = [0];
  while (remaining.size) {
    const from = order[order.length - 1]; let next = -1, score = [Infinity, Infinity];
    for (const candidate of remaining) {
      const cost = [matrix.times[from][candidate], matrix.distances[from][candidate]];
      if (better(cost, score)) { next = candidate; score = cost; }
    }
    order.push(next); remaining.delete(next);
  }
  // Bounded deterministic improvement, O(passes*n²) using prefix sums for asymmetric reversals.
  for (let pass = 0; pass < Math.min(32, order.length); pass++) {
    const prefixes = [matrix.times, matrix.distances].map(m => {
      const p = [0];
      for (let i = 0; i + 1 < order.length; i++)
        p.push(p[i] + m[order[i + 1]][order[i]] - m[order[i]][order[i + 1]]);
      return p;
    });
    let change = [0, 0], left = -1, right = -1;
    for (let i = 1; i < order.length - 1; i++) for (let j = i + 1; j < order.length; j++) {
      const before = order[i - 1], first = order[i], last = order[j];
      const after = j + 1 < order.length ? order[j + 1] : closed ? order[0] : null;
      const delta = [matrix.times, matrix.distances].map((m, dimension) =>
        m[before][last] - m[before][first] + prefixes[dimension][j] - prefixes[dimension][i] +
        (after === null ? 0 : m[first][after] - m[last][after]));
      if (better(delta, change)) { change = delta; left = i; right = j; }
    }
    if (left < 0) break;
    order.splice(left, right - left + 1, ...order.slice(left, right + 1).reverse());
  }
  return order;
}

