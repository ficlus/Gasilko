
'use client';

import { useEffect, useState } from 'react';
import type { ViewportBounds } from '../map/OperationalMapCanvas';
import type { HydrantViewport } from '../../lib/hydrants/viewport';

const EMPTY: HydrantViewport = { rows: [], more: false };

type HydrantSnapshot = {
  account: string;
  data: HydrantViewport;
};

export function useHydrantContext(
  account: string,
  bounds: ViewportBounds | null,
  enabled: boolean,
  refresh: number
) {
  const [snapshot, setSnapshot] = useState<HydrantSnapshot>({
    account,
    data: EMPTY,
  });

  const [error, setError] = useState(false);
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    const controller = new AbortController();

    setError(false);

    if (!enabled || !bounds || !account) {
      setSnapshot({ account, data: EMPTY });
      setLoading(false);
      return () => controller.abort();
    }

    // Keep currently displayed hydrants during a normal viewport refresh.
    // A previous account's data is hidden by the return guard below.
    setLoading(true);

    const timer = setTimeout(() => {
      void fetch('/api/hydrant-context', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Gasilko-Account': account,
        },
        body: JSON.stringify({ bounds }),
        cache: 'no-store',
        signal: controller.signal,
      })
        .then(async (response) => {
          if (!response.ok) {
            // Authentication or authorization failures must not retain
            // previously visible hydrant data.
            if (
              (response.status === 401 || response.status === 403) &&
              !controller.signal.aborted
            ) {
              setSnapshot({ account, data: EMPTY });
            }

            throw new Error('HYDRANT_CONTEXT_UNAVAILABLE');
          }

          const data = (await response.json()) as HydrantViewport;

          if (!controller.signal.aborted) {
            setSnapshot({ account, data });
          }
        })
        .catch(() => {
          if (!controller.signal.aborted) {
            // Keep last valid data on temporary network/server errors.
            setError(true);
          }
        })
        .finally(() => {
          if (!controller.signal.aborted) {
            setLoading(false);
          }
        });
    }, 300);

    return () => {
      clearTimeout(timer);
      controller.abort();
    };
  }, [account, bounds, enabled, refresh]);

  // Never expose another account's cached hydrants.
  // Also hide all hydrants immediately if this layer becomes disabled.
  const visible =
    enabled && bounds && snapshot.account === account
      ? snapshot.data
      : EMPTY;

  return {
    ...visible,
    error,
    loading,
  };
}
