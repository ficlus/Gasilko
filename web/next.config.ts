import type { NextConfig } from 'next';
const config: NextConfig = { poweredByHeader: false, output: 'standalone',
  serverExternalPackages: ['xlsx'],
  outputFileTracingIncludes: { '/api/exchange': ['./scripts/spreadsheet.cjs', './node_modules/xlsx/**/*'] }
};
export default config;
