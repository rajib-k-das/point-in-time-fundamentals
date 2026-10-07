{#- A Piotroski-style binary signal: 1 if the comparison holds, 0 if not, null if either side is unknown.
    Unknown inputs are never silently scored as 0. -#}
{% macro compare_signal(left, operator, right) -%}
    case
        when ({{ left }}) is null or ({{ right }}) is null then null
        when ({{ left }}) {{ operator }} ({{ right }}) then 1
        else 0
    end
{%- endmacro %}
