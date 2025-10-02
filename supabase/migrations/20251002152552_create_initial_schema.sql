CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    full_name TEXT NOT NULL,
    avatar_url TEXT,
    created_at TIMESTAMPTZ DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.groups (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    currency TEXT NOT NULL DEFAULT 'USD',
    created_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.group_members (
    group_id UUID NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    role TEXT NOT NULL DEFAULT 'member',
    joined_at TIMESTAMPTZ DEFAULT timezone('utc'::text, now()) NOT NULL,
    PRIMARY KEY (group_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.expenses (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    group_id UUID NOT NULL REFERENCES public.groups(id) ON DELETE CASCADE,
    description TEXT NOT NULL,
    amount_cents INTEGER NOT NULL CHECK (amount_cents >= 0),
    currency TEXT NOT NULL,
    paid_by UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT timezone('utc'::text, now()) NOT NULL,
    deleted_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS public.expense_splits (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    expense_id UUID NOT NULL REFERENCES public.expenses(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    share_cents INTEGER NOT NULL CHECK (share_cents >= 0)
);

CREATE INDEX IF NOT EXISTS idx_group_members_user_id ON public.group_members(user_id);
CREATE INDEX IF NOT EXISTS idx_group_members_group_id ON public.group_members(group_id);
CREATE INDEX IF NOT EXISTS idx_expenses_group_id ON public.expenses(group_id);
CREATE INDEX IF NOT EXISTS idx_expenses_paid_by ON public.expenses(paid_by);
CREATE INDEX IF NOT EXISTS idx_expenses_deleted_at ON public.expenses(deleted_at);
CREATE INDEX IF NOT EXISTS idx_expense_splits_expense_id ON public.expense_splits(expense_id);
CREATE INDEX IF NOT EXISTS idx_expense_splits_user_id ON public.expense_splits(user_id);

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expense_splits ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Profiles are viewable by authenticated users"
    ON public.profiles FOR SELECT
    TO authenticated
    USING (true);

CREATE POLICY "Users can update own profile"
    ON public.profiles FOR UPDATE
    TO authenticated
    USING (auth.uid() = id);

-- Users can insert their own profile
CREATE POLICY "Users can insert own profile"
    ON public.profiles FOR INSERT
    TO authenticated
    WITH CHECK (auth.uid() = id);

-- RLS Policies for groups table
-- Users can view groups they are members of
CREATE POLICY "Users can view groups they are members of"
    ON public.groups FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.group_members
            WHERE group_members.group_id = groups.id
            AND group_members.user_id = auth.uid()
        )
    );

-- Any authenticated user can create a group
CREATE POLICY "Authenticated users can create groups"
    ON public.groups FOR INSERT
    TO authenticated
    WITH CHECK (auth.uid() = created_by);

-- Only group creators can update groups
CREATE POLICY "Group creators can update groups"
    ON public.groups FOR UPDATE
    TO authenticated
    USING (auth.uid() = created_by);

-- RLS Policies for group_members table
-- Users can view members of groups they belong to
CREATE POLICY "Users can view members of their groups"
    ON public.group_members FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.group_members gm
            WHERE gm.group_id = group_members.group_id
            AND gm.user_id = auth.uid()
        )
    );

-- Group creators can add members
CREATE POLICY "Group creators can add members"
    ON public.group_members FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.groups
            WHERE groups.id = group_members.group_id
            AND groups.created_by = auth.uid()
        )
    );

-- Group creators can remove members
CREATE POLICY "Group creators can remove members"
    ON public.group_members FOR DELETE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.groups
            WHERE groups.id = group_members.group_id
            AND groups.created_by = auth.uid()
        )
    );

-- RLS Policies for expenses table
-- Users can view expenses in groups they are members of
CREATE POLICY "Users can view expenses in their groups"
    ON public.expenses FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.group_members
            WHERE group_members.group_id = expenses.group_id
            AND group_members.user_id = auth.uid()
        )
    );

-- Group members can create expenses
CREATE POLICY "Group members can create expenses"
    ON public.expenses FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.group_members
            WHERE group_members.group_id = expenses.group_id
            AND group_members.user_id = auth.uid()
        )
    );

-- Users can update (soft delete) their own expenses
CREATE POLICY "Users can update their own expenses"
    ON public.expenses FOR UPDATE
    TO authenticated
    USING (auth.uid() = paid_by);

-- RLS Policies for expense_splits table
-- Users can view splits for expenses in their groups
CREATE POLICY "Users can view splits in their groups"
    ON public.expense_splits FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.expenses e
            JOIN public.group_members gm ON gm.group_id = e.group_id
            WHERE e.id = expense_splits.expense_id
            AND gm.user_id = auth.uid()
        )
    );

-- Allow inserts via RPC (handled by create_equal_expense function)
CREATE POLICY "Allow splits insert via RPC"
    ON public.expense_splits FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.expenses e
            JOIN public.group_members gm ON gm.group_id = e.group_id
            WHERE e.id = expense_splits.expense_id
            AND gm.user_id = auth.uid()
        )
    );

-- Function to handle new user signup (creates profile automatically)
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.profiles (id, full_name, avatar_url)
    VALUES (
        new.id,
        COALESCE(new.raw_user_meta_data->>'full_name', new.email),
        new.raw_user_meta_data->>'avatar_url'
    );
    RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger to automatically create profile on user signup
CREATE OR REPLACE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

