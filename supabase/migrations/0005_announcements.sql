-- Household announcements table for pinned messages and important updates
CREATE TABLE IF NOT EXISTS announcements (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  household_id UUID NOT NULL REFERENCES households(id) ON DELETE CASCADE,
  created_by_member_id UUID NOT NULL REFERENCES household_members(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  message TEXT NOT NULL DEFAULT '',
  is_pinned BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_announcements_household_id ON announcements(household_id);
CREATE INDEX IF NOT EXISTS idx_announcements_created_by ON announcements(created_by_member_id);
CREATE INDEX IF NOT EXISTS idx_announcements_pinned ON announcements(household_id, is_pinned) WHERE is_pinned = TRUE;

-- Enable RLS
ALTER TABLE announcements ENABLE ROW LEVEL SECURITY;

-- RLS Policies
CREATE POLICY "Household members can view announcements"
  ON announcements FOR SELECT
  USING (
    household_id IN (
      SELECT household_id FROM household_members
      WHERE auth_user_id = auth.uid()
    )
  );

CREATE POLICY "Admins can insert announcements"
  ON announcements FOR INSERT
  WITH CHECK (
    household_id IN (
      SELECT household_id FROM household_members
      WHERE auth_user_id = auth.uid() AND role IN ('owner', 'admin')
    )
  );

CREATE POLICY "Admins can update announcements"
  ON announcements FOR UPDATE
  USING (
    household_id IN (
      SELECT household_id FROM household_members
      WHERE auth_user_id = auth.uid() AND role IN ('owner', 'admin')
    )
  );

CREATE POLICY "Admins can delete announcements"
  ON announcements FOR DELETE
  USING (
    household_id IN (
      SELECT household_id FROM household_members
      WHERE auth_user_id = auth.uid() AND role IN ('owner', 'admin')
    )
  );

-- Updated at trigger
CREATE OR REPLACE FUNCTION update_announcements_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_announcements_updated_at
  BEFORE UPDATE ON announcements
  FOR EACH ROW
  EXECUTE FUNCTION update_announcements_updated_at();
