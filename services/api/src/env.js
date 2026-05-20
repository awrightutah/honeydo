import dotenv from 'dotenv';
import { z } from 'zod';

dotenv.config();

const envSchema = z.object({
  NODE_ENV: z.string().default('development'),
  PORT: z.coerce.number().default(3000),
  SUPABASE_URL: z.string().url(),
  SUPABASE_SERVICE_ROLE_KEY: z.string().min(1),
  AUTHORIZE_NET_API_LOGIN_ID: z.string().optional(),
  AUTHORIZE_NET_TRANSACTION_KEY: z.string().optional(),
  AUTHORIZE_NET_SIGNATURE_KEY: z.string().optional(),
});

export const env = envSchema.parse({
  NODE_ENV: process.env.NODE_ENV,
  PORT: process.env.PORT,
  SUPABASE_URL: process.env.SUPABASE_URL,
  SUPABASE_SERVICE_ROLE_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY,
  AUTHORIZE_NET_API_LOGIN_ID: process.env.AUTHORIZE_NET_API_LOGIN_ID,
  AUTHORIZE_NET_TRANSACTION_KEY: process.env.AUTHORIZE_NET_TRANSACTION_KEY,
  AUTHORIZE_NET_SIGNATURE_KEY: process.env.AUTHORIZE_NET_SIGNATURE_KEY,
});
