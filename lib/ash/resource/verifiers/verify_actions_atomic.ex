defmodule Ash.Resource.Verifiers.VerifyActionsAtomic do
  @moduledoc """
  Raises an error on update or destroy actions with `require_atomic?` set to
  true when it is known at compile time that they will not be atomic.
  """
  use Spark.Dsl.Verifier

  def verify(dsl) do
    module = Spark.Dsl.Verifier.get_persisted(dsl, :module)

    warnings =
      dsl
      |> Ash.Resource.Info.actions()
      |> Enum.filter(
        &(&1.type in [:update, :destroy] && &1.require_atomic? &&
            data_layer_can_atomic?(module, &1))
      )
      |> Enum.flat_map(fn action ->
        warnings =
          if action.manual do
            [
              Spark.Error.DslError.exception(
                module: module,
                message:
                  non_atomic_message(
                    module,
                    action.name,
                    "manual actions cannot be done atomically"
                  ),
                path: [:actions, action.name]
              )
            ]
          else
            []
          end

        change_warnings =
          action.changes
          |> Enum.concat(Ash.Resource.Info.changes(dsl, action.type))
          |> Enum.concat(Ash.Resource.Info.validations(dsl, action.type))
          |> Enum.map(fn
            %{change: {module, _}} ->
              module

            %{validation: {module, _}} ->
              module
          end)
          |> Enum.reject(fn module ->
            module.atomic?()
          end)
          |> case do
            [] ->
              []

            non_atomic_change_modules ->
              [
                Spark.Error.DslError.exception(
                  module: module,
                  message:
                    non_atomic_message(
                      module,
                      action.name,
                      "the changes `#{inspect(non_atomic_change_modules)}` cannot be done atomically"
                    ),
                  path: [:actions, action.name]
                )
              ]
          end

        notifier_warnings =
          dsl
          |> Ash.Resource.Info.notifiers()
          |> Enum.filter(fn notifier ->
            notifier.requires_original_data?(module, action.name)
          end)
          |> case do
            [] ->
              []

            non_atomic_notifier_modules ->
              [
                Spark.Error.DslError.exception(
                  module: module,
                  message:
                    non_atomic_message(
                      module,
                      action.name,
                      "the notifiers `#{inspect(non_atomic_notifier_modules)}` cannot be done atomically"
                    ),
                  path: [:actions, action.name]
                )
              ]
          end

        attribute_warnings =
          action.accept
          |> Enum.map(&Ash.Resource.Info.attribute(dsl, &1))
          |> Enum.filter(fn %{type: type, constraints: constraints} ->
            case type do
              {:array, {:array, _}} ->
                true

              {:array, type} when is_atom(type) ->
                not_atomic?(type, constraints, action)

              type when is_atom(type) ->
                not_atomic?(type, constraints, action)

              _ ->
                false
            end
          end)
          |> case do
            [] ->
              []

            not_atomic_attributes ->
              [
                Spark.Error.DslError.exception(
                  module: module,
                  message:
                    non_atomic_message(
                      module,
                      action.name,
                      "the attributes `#{Enum.map_join(not_atomic_attributes, ", ", & &1.name)}` cannot be updated atomically"
                    ),
                  path: [:actions, action.name]
                )
              ]
          end

        warnings ++ change_warnings ++ notifier_warnings ++ attribute_warnings
      end)

    {:warn, Enum.map(warnings, &Exception.message/1)}
  end

  defp data_layer_can_atomic?(resource, %{type: :update}) do
    Ash.DataLayer.can?(:update_query, resource)
  end

  defp data_layer_can_atomic?(resource, %{type: :destroy}) do
    Ash.DataLayer.can?(:destroy_query, resource)
  end

  defp not_atomic?(type, constraints, %{type: :update}) do
    type = Ash.Type.get_type(type)

    new_type =
      if Ash.Type.NewType.new_type?(type) do
        Ash.Type.NewType.subtype_of(type)
      else
        type
      end

    constraints =
      if Ash.Type.NewType.new_type?(type) do
        Ash.Type.NewType.constraints(new_type, constraints)
      else
        constraints
      end

    !new_type.may_support_atomic_update?(constraints)
  end

  defp not_atomic?(type, constraints, %{type: :destroy, soft?: true} = action)
       when is_atom(type) do
    not_atomic?(type, constraints, %{action | type: :update})
  end

  defp not_atomic?(_, _, _), do: false

  defp non_atomic_message(module, action_name, reason) do
    """
    `#{inspect(module)}.#{action_name}` cannot be done atomically, because #{reason}

    You must either address the issue or set `require_atomic? false` on `#{inspect(module)}.#{action_name}`.

    If this action is defined in defaults, i.e `defaults [update: [:accepted, :attr]]`, you must define it like so:

        update :update do
          accept [:accepted, :attr]
          require_atomic? false
        end
    """
  end
end
