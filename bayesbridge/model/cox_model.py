from .abstract_model import AbstractModel
import numpy as np
import scipy as sp
from bayesbridge.util.simple_warnings import warn_message_only


class CoxModel(AbstractModel):

    def __init__(self, event_time, censoring_time, X):
        """

        Parameters
        ----------
        event_time : numpy array
            The lowest values indicate the earliest events. float('inf')
            indicates right-censoring.
        censoring_time : numpy array
            float('inf') indicates uncensored observations.
        """

        if np.any(event_time[:-1] > event_time[1:]):
            raise ValueError(
                "The observations need to be sorted so that the event times are "
                "in the increasing order, from the earliest to last events."
            )

        if np.any(censoring_time[:-1] < censoring_time[1:]):
            raise ValueError(
                "The observations need to be sorted so that the censoring times "
                "are in the increasing order, from uncensored, last censored, "
                "to the earliest censored."
            )

        n_appearance = \
            CoxModel.count_risk_set_appearance(event_time, censoring_time)
        if not np.all(n_appearance >= 1):
            raise ValueError(
                "Some individuals never appear in the risk set. They have to be"
                "removed before using the CoxModel class.")

        self.n_event = len(event_time) - np.sum(np.isinf(event_time))
        self.event_time = event_time
        self.censoring_time = censoring_time
        self.n_appearance_in_risk_set = n_appearance
        self.risk_set_end_index = np.array([
            np.sum(t < censoring_time) - 1 for t in event_time[:self.n_event]
        ])  # TODO: Should I consider the day of censoring to be in the risk set?
        self.X = X
        self.name = 'cox'

    @staticmethod
    def permute_observations_by_event_and_censoring_time(
            event_time, censoring_time, X):
        """
        Permute the observations so that they are ordered from the earliest
        to the last to experience events, followed by the last censored to the
        earliest censored.

        Params
        ------
        event_time : numpy array
            The lowest values indicate the earliest events. float('inf')
            indicates right-censoring.
        X : numpy array or scipy sparse matrix
        """
        if not np.all(np.equal(
                event_time == float("inf"),
                censoring_time < float('inf')
            )):
            raise ValueError("Censoring indicators are inconsistent.")

        n_event = np.sum(event_time < float('inf'))
        event_rank = CoxModel.np_rank_by_value(event_time)
        censoring_rank = CoxModel.np_rank_by_value(censoring_time)
        sort_ind = np.concatenate((
            np.argsort(event_rank)[:n_event],
            np.argsort(- censoring_rank)[n_event:]
        ))
        assert len(np.unique(sort_ind)) == len(sort_ind)

        event_time = event_time[sort_ind]
        censoring_time = censoring_time[sort_ind]
        if sp.sparse.issparse(X):
            X = X.tocsr()[sort_ind, :]
        else:
            X = X[sort_ind, :]
        return event_time, censoring_time, X

    @staticmethod
    def np_rank_by_value(arr):
        sort_arguments = np.argsort(arr)
        rank = np.arange(len(arr))[np.argsort(sort_arguments)]
        return rank.astype('float')

    @staticmethod
    def count_risk_set_appearance(event_time, censoring_time):
        """ This function assumes that the observations are already sorted in
        the way required by the class. """

        # The calculation can be done more efficiently.
        n_appearance = np.zeros(len(censoring_time), dtype=np.int)
        for t in event_time[event_time < float('inf')]:
            # TODO: Should I consider the day of censoring to be in the risk set?
            index = np.logical_and(censoring_time >= t, event_time >= t)
            n_appearance[index] += 1
        return n_appearance

    def compute_loglik_and_gradient(self, beta, loglik_only=False):

        log_hazard_increase, hazard_increase, sum_over_risk_set \
            = self._compute_hazard_increase(beta)

        loglik = np.sum(
            log_hazard_increase[:self.n_event] - np.log(sum_over_risk_set)
        )

        grad = None
        if not loglik_only:
            hazard_matrix = self._HazardMultinomialProbMatrix(
                hazard_increase, sum_over_risk_set,
                self.risk_set_end_index, self.n_appearance_in_risk_set
            )
            v = np.zeros(self.X.shape[0])
            v[:self.n_event] = 1
            v -= hazard_matrix.sum_over_events()
            grad = self.X.Tdot(v)

        return loglik, grad

    def _compute_hazard_increase(self, beta):

        log_hazard_increase = self.X.dot(beta)
        log_hazard_increase = CoxModel._shift_log_hazard(log_hazard_increase)

        hazard_increase = np.exp(log_hazard_increase)

        sum_over_risk_set = \
            self._sum_over_risk_set(hazard_increase, self.risk_set_end_index)

        return log_hazard_increase, hazard_increase, sum_over_risk_set

    @staticmethod
    def _sum_over_risk_set(arr, risk_set_end_index):
        """
        Returns
        -------
        numpy array of length 'n_event' whose k-th element equals
            np.sum(arr[k:risk_set_end_index[k]])
        """
        n_event = len(risk_set_end_index)
        sum_from_right_over_risk_set = \
            np.cumsum(arr[(n_event - 1):])[risk_set_end_index - n_event + 1]
        sum_from_left_over_risk_set = np.concatenate((
            CoxModel.np_reverse_cumsum(arr[:(n_event - 1)]), [0]
        ))
        sum_over_risk_set = \
            sum_from_right_over_risk_set + sum_from_left_over_risk_set
        return sum_over_risk_set

    @staticmethod
    def np_reverse_cumsum(arr):
        return np.cumsum(arr[::-1])[::-1]

    @staticmethod
    def _shift_log_hazard(log_hazard_rate, log_offset=0):
        """
        Shift the values so that the max value equals 'log_offset' to
        prevent numerical under / over-flow before taking exponential.
        """
        log_hazard_rate += log_offset - np.max(log_hazard_rate)
        return log_hazard_rate

    def compute_hessian(self, beta):
        raise NotImplementedError()

    def get_hessian_matvec_operator(self, beta):

        _, hazard_increase, sum_over_risk_set \
            = self._compute_hazard_increase(beta)
        W = self._HazardMultinomialProbMatrix(
            hazard_increase, sum_over_risk_set,
            self.risk_set_end_index, self.n_appearance_in_risk_set
        )
        def hessian_op(beta):
            X_beta = self.X.dot(beta)
            result_vec = - self.X.Tdot(
                W.sum_over_events() * X_beta - W.Tdot(W.dot(X_beta))
            )
            return result_vec

        return hessian_op

    @staticmethod
    def simulate_outcome(X, beta, censoring_frac=.9, seed=None):
        """
        Simulate an outcome from a constant baseline hazard model i.e. the
        survival time is exponential.
        """
        if seed is not None:
            np.random.seed(seed)

        log_hazard_rate = X.dot(beta)
        log_hazard_rate = CoxModel._shift_log_hazard(log_hazard_rate)
        hazard_rate = np.exp(log_hazard_rate)
        event_time = np.random.exponential(scale=hazard_rate ** -1)

        scale = CoxModel._solve_for_exp_scale(
            np.quantile(event_time, 1 - censoring_frac), 1 - censoring_frac
        )
        censoring_time = np.random.exponential(
            scale=scale * np.ones(len(hazard_rate))
        )
        censoring_time[event_time < censoring_time] = float("inf")
        event_time[event_time >= censoring_time] = float('inf')

        return event_time, censoring_time

    @staticmethod
    def _solve_for_exp_scale(t, prob):
        """
        Computes the scale of an exponential random variable Z such that
            P(Z < t) == prob
        """
        return - t / np.log(1 - prob)

    class _HazardMultinomialProbMatrix():
        """
        Defines operations by a matrix whose each row represents the conditional
        probabilities of the event happening to the individuals in the risk set.
        """

        def __init__(self, hazard_increase, sum_over_risk_set,
                     risk_set_end_index, n_appearance_in_risk_set):
            self.hazard_increase = hazard_increase
            self.sum_over_risk_set = sum_over_risk_set
            self.risk_set_end_index = risk_set_end_index
            self.n_appearance_in_risk_set = n_appearance_in_risk_set
            self.n_event = len(sum_over_risk_set)


        def sum_over_events(self):
            """
            Returns the same value as the row sum of the explicitly computed
            the matrix (e.g. via the 'compute_matrix' method) but do it more
            efficiently.
            """
            normalizer_cumsum = np.cumsum(self.sum_over_risk_set ** -1)
            row_sum = normalizer_cumsum[self.n_appearance_in_risk_set - 1] \
                      * self.hazard_increase
            if (self.risk_set_end_index[0] + 1) < len(self.hazard_increase):
                row_sum[(self.risk_set_end_index[0] + 1):] = 0
            return row_sum

        def dot(self, v):
            return self.sum_over_risk_set ** - 1 * CoxModel._sum_over_risk_set(
                self.hazard_increase * v, self.risk_set_end_index
            )

        def Tdot(self, v):
            partial_inner_prod = np.cumsum(self.sum_over_risk_set ** -1 * v)
            return self.hazard_increase \
                   * partial_inner_prod[self.n_appearance_in_risk_set - 1]

        def compute_matrix(self):
            multinomial_prob = np.outer(
                self.sum_over_risk_set ** -1,
                self.hazard_increase
            )
            multinomial_prob = np.triu(multinomial_prob)
            for i in range(1, multinomial_prob.shape[0] + 1):
                if (self.risk_set_end_index[-i] + 1) >= len(self.hazard_increase):
                    break
                multinomial_prob[-i, (self.risk_set_end_index[-i] + 1):] = 0

            return multinomial_prob