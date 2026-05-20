-- Chore comments table for discussion on individual chores
CREATE TABLE IF NOT EXISTS chore_comments (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  chore_id UUID NOT NULL REFERENCES chores(id) ON DELETE CASCADE,
  member_id UUID NOT NULL REFERENCES household_members(id) ON DELETE CASCADE,
  comment TEXT NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_chore_comments_chore_id ON chore_comments(chore_id);
CREATE INDEX IF NOT EXISTS idx_chore_comments_member_id ON chore_comments(member_id);
CREATE INDEX IF NOT EXISTS idx_chore_comments_created_at ON chore_comments(created_at DESC);

-- Enable RLS
ALTER TABLE chore_comments ENABLE ROW LEVEL SECURITY;

-- RLS Policies: Household members can read/write comments for their household's chores
CREATE POLICY "Household members can view chore comments"
  ON chore_comments FOR SELECT
  USING (
    EXISTS (
      SELECT 1 FROM chores
      WHERE chores.id = chore_comments.chore_id
      AND chores.household_id IN (
        SELECT household_id FROM household_members
        WHERE household_members.id = chore_comments.member_id
      )
    )
  );

CREATE POLICY "Household members can insert chore comments"
  ON chore_comments FOR INSERT
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM chores
      WHERE chores.id = chore_comments.chore_id
      AND chores.household_id IN (
        SELECT household_id FROM household_members
        WHERE household_members.id = chore_comments.member_id
      )
    )
  );

CREATE POLICY "Comment authors can update their own comments"
  ON chore_comments FOR UPDATE
  USING (member_id = auth.uid()::text);

CREATE POLICY "Comment authors can delete their own comments"
  ON chore_comments FOR DELETE
  USING (member_id = auth.uid()::text);

-- Updated at trigger
CREATE OR REPLACE FUNCTION update_chore_comments_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_chore_comments_updated_at
  BEFORE UPDATE ON chore_comments
  FOR EACH ROW
  EXECUTE FUNCTION update_chore_comments_updated_at();