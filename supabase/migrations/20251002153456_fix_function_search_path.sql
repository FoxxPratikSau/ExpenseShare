-- Fix search_path security issue by setting it explicitly on all SECURITY DEFINER functions
-- This prevents search_path hijacking attacks

-- Fix handle_new_user function
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    INSERT INTO public.profiles (id, full_name, avatar_url)
    VALUES (
        new.id,
        COALESCE(new.raw_user_meta_data->>'full_name', new.email),
        new.raw_user_meta_data->>'avatar_url'
    );
    RETURN new;
END;
$$;

-- Fix create_equal_expense function
CREATE OR REPLACE FUNCTION public.create_equal_expense(
    p_group_id UUID,
    p_description TEXT,
    p_amount_cents INTEGER,
    p_paid_by UUID,
    p_participants UUID[]
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_expense_id UUID;
    v_num_participants INTEGER;
    v_base_share INTEGER;
    v_remainder INTEGER;
    v_participant UUID;
    v_index INTEGER := 0;
    v_currency TEXT;
BEGIN
    IF p_amount_cents < 0 THEN
        RAISE EXCEPTION 'Amount must be non-negative';
    END IF;

    IF array_length(p_participants, 1) IS NULL OR array_length(p_participants, 1) = 0 THEN
        RAISE EXCEPTION 'At least one participant is required';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.group_members
        WHERE group_id = p_group_id
        AND user_id = auth.uid()
    ) THEN
        RAISE EXCEPTION 'You are not a member of this group';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM public.group_members
        WHERE group_id = p_group_id
        AND user_id = p_paid_by
    ) THEN
        RAISE EXCEPTION 'Payer must be a member of the group';
    END IF;

    IF EXISTS (
        SELECT 1 FROM unnest(p_participants) AS participant_id
        WHERE NOT EXISTS (
            SELECT 1 FROM public.group_members
            WHERE group_id = p_group_id
            AND user_id = participant_id
        )
    ) THEN
        RAISE EXCEPTION 'All participants must be members of the group';
    END IF;

    SELECT currency INTO v_currency
    FROM public.groups
    WHERE id = p_group_id;

    v_num_participants := array_length(p_participants, 1);
    v_base_share := p_amount_cents / v_num_participants;
    v_remainder := p_amount_cents % v_num_participants;

    INSERT INTO public.expenses (group_id, description, amount_cents, currency, paid_by)
    VALUES (p_group_id, p_description, p_amount_cents, v_currency, p_paid_by)
    RETURNING id INTO v_expense_id;

    FOREACH v_participant IN ARRAY p_participants
    LOOP
        INSERT INTO public.expense_splits (expense_id, user_id, share_cents)
        VALUES (
            v_expense_id,
            v_participant,
            v_base_share + (CASE WHEN v_index < v_remainder THEN 1 ELSE 0 END)
        );
        v_index := v_index + 1;
    END LOOP;

    RETURN v_expense_id;
END;
$$;

-- Fix get_group_balances function
CREATE OR REPLACE FUNCTION public.get_group_balances(p_group_id UUID)
RETURNS TABLE (
    user_id UUID,
    user_name TEXT,
    net_cents INTEGER
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.group_members
        WHERE group_id = p_group_id
        AND user_id = auth.uid()
    ) THEN
        RAISE EXCEPTION 'You are not a member of this group';
    END IF;

    RETURN QUERY
    WITH member_list AS (
        SELECT gm.user_id, p.full_name as user_name
        FROM public.group_members gm
        JOIN public.profiles p ON p.id = gm.user_id
        WHERE gm.group_id = p_group_id
    ),
    paid_amounts AS (
        SELECT 
            e.paid_by as user_id,
            COALESCE(SUM(e.amount_cents), 0) as total_paid
        FROM public.expenses e
        WHERE e.group_id = p_group_id
        AND e.deleted_at IS NULL
        GROUP BY e.paid_by
    ),
    owed_amounts AS (
        SELECT 
            es.user_id,
            COALESCE(SUM(es.share_cents), 0) as total_owed
        FROM public.expense_splits es
        JOIN public.expenses e ON e.id = es.expense_id
        WHERE e.group_id = p_group_id
        AND e.deleted_at IS NULL
        GROUP BY es.user_id
    )
    SELECT 
        ml.user_id,
        ml.user_name,
        COALESCE(pa.total_paid, 0) - COALESCE(oa.total_owed, 0) as net_cents
    FROM member_list ml
    LEFT JOIN paid_amounts pa ON pa.user_id = ml.user_id
    LEFT JOIN owed_amounts oa ON oa.user_id = ml.user_id
    ORDER BY ml.user_name;
END;
$$;

