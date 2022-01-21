!--------------------------------------------------------------------------------------------------
!> @author Pratheek Shanthraj, Max-Planck-Institut für Eisenforschung GmbH
!> @author Martin Diehl, Max-Planck-Institut für Eisenforschung GmbH
!> @author Philip Eisenlohr, Max-Planck-Institut für Eisenforschung GmbH
!> @brief Grid solver for mechanics: Spectral Polarisation
!--------------------------------------------------------------------------------------------------
module grid_mechanical_spectral_polarisation
#include <petsc/finclude/petscsnes.h>
#include <petsc/finclude/petscdmda.h>
  use PETScDMDA
  use PETScSNES
#if (PETSC_VERSION_MAJOR==3 && PETSC_VERSION_MINOR>14) && !defined(PETSC_HAVE_MPI_F90MODULE_VISIBILITY)
  use MPI_f08
#endif

  use prec
  use parallelization
  use DAMASK_interface
  use IO
  use HDF5
  use HDF5_utilities
  use math
  use rotations
  use spectral_utilities
  use config
  use homogenization
  use discretization_grid

  implicit none
  private

  type(tSolutionParams) :: params

  type :: tNumerics
    logical :: update_gamma                                                                         !< update gamma operator with current stiffness
    integer :: &
      itmin, &                                                                                      !< minimum number of iterations
      itmax                                                                                         !< maximum number of iterations
    real(pReal) :: &
      eps_div_atol, &                                                                               !< absolute tolerance for equilibrium
      eps_div_rtol, &                                                                               !< relative tolerance for equilibrium
      eps_curl_atol, &                                                                              !< absolute tolerance for compatibility
      eps_curl_rtol, &                                                                              !< relative tolerance for compatibility
      eps_stress_atol, &                                                                            !< absolute tolerance for fullfillment of stress BC
      eps_stress_rtol                                                                               !< relative tolerance for fullfillment of stress BC
    real(pReal) :: &
      alpha, &                                                                                      !< polarization scheme parameter 0.0 < alpha < 2.0. alpha = 1.0 ==> AL scheme, alpha = 2.0 ==> accelerated scheme
      beta                                                                                          !< polarization scheme parameter 0.0 < beta < 2.0. beta = 1.0 ==> AL scheme, beta = 2.0 ==> accelerated scheme
  end type tNumerics

  type(tNumerics) :: num                                                                            ! numerics parameters. Better name?

  logical :: debugRotation

!--------------------------------------------------------------------------------------------------
! PETSc data
  DM   :: da
  SNES :: SNES_mechanical
  Vec  :: solution_vec

!--------------------------------------------------------------------------------------------------
! common pointwise data
  real(pReal), dimension(:,:,:,:,:), allocatable :: &
    F_lastInc, &                                                                                    !< field of previous compatible deformation gradients
    F_tau_lastInc, &                                                                                !< field of previous incompatible deformation gradient
    Fdot, &                                                                                         !< field of assumed rate of compatible deformation gradient
    F_tauDot                                                                                        !< field of assumed rate of incopatible deformation gradient

!--------------------------------------------------------------------------------------------------
! stress, stiffness and compliance average etc.
  real(pReal), dimension(3,3) :: &
    F_aimDot = 0.0_pReal, &                                                                         !< assumed rate of average deformation gradient
    F_aim = math_I3, &                                                                              !< current prescribed deformation gradient
    F_aim_lastInc = math_I3, &                                                                      !< previous average deformation gradient
    F_av = 0.0_pReal, &                                                                             !< average incompatible def grad field
    P_av = 0.0_pReal, &                                                                             !< average 1st Piola--Kirchhoff stress
    P_aim = 0.0_pReal
  character(len=:), allocatable :: incInfo                                                          !< time and increment information
  real(pReal), dimension(3,3,3,3) :: &
    C_volAvg = 0.0_pReal, &                                                                         !< current volume average stiffness
    C_volAvgLastInc = 0.0_pReal, &                                                                  !< previous volume average stiffness
    C_minMaxAvg = 0.0_pReal, &                                                                      !< current (min+max)/2 stiffness
    C_minMaxAvgLastInc = 0.0_pReal, &                                                               !< previous (min+max)/2 stiffness
    S = 0.0_pReal, &                                                                                !< current compliance (filled up with zeros)
    C_scale = 0.0_pReal, &
    S_scale = 0.0_pReal

  real(pReal) :: &
    err_BC, &                                                                                       !< deviation from stress BC
    err_curl, &                                                                                     !< RMS of curl of F
    err_div                                                                                         !< RMS of div of P

  integer :: &
    totalIter = 0                                                                                   !< total iteration in current increment

  public :: &
    grid_mechanical_spectral_polarisation_init, &
    grid_mechanical_spectral_polarisation_solution, &
    grid_mechanical_spectral_polarisation_forward, &
    grid_mechanical_spectral_polarisation_updateCoords, &
    grid_mechanical_spectral_polarisation_restartWrite

contains

!--------------------------------------------------------------------------------------------------
!> @brief allocates all necessary fields and fills them with data, potentially from restart info
!--------------------------------------------------------------------------------------------------
subroutine grid_mechanical_spectral_polarisation_init

  real(pReal), dimension(3,3,grid(1),grid(2),grid3) :: P
  PetscErrorCode :: err_PETSc
  integer(MPI_INTEGER_KIND) :: err_MPI
  PetscScalar, pointer, dimension(:,:,:,:) :: &
    FandF_tau, &                                                                                    ! overall pointer to solution data
    F, &                                                                                            ! specific (sub)pointer
    F_tau                                                                                           ! specific (sub)pointer
  PetscInt, dimension(0:worldsize-1) :: localK
  integer(HID_T) :: fileHandle, groupHandle
#if (PETSC_VERSION_MAJOR==3 && PETSC_VERSION_MINOR>14) && !defined(PETSC_HAVE_MPI_F90MODULE_VISIBILITY)
  type(MPI_File) :: fileUnit
#else
  integer :: fileUnit
#endif
  class (tNode), pointer :: &
    num_grid, &
    debug_grid

  print'(/,1x,a)', '<<<+-  grid_mechanical_spectral_polarization init  -+>>>'; flush(IO_STDOUT)

  print'(/,1x,a)', 'P. Shanthraj et al., International Journal of Plasticity 66:31–45, 2015'
  print'(  1x,a)', 'https://doi.org/10.1016/j.ijplas.2014.02.006'

!-------------------------------------------------------------------------------------------------
! debugging options
  debug_grid => config_debug%get('grid',defaultVal=emptyList)
  debugRotation = debug_grid%contains('rotation')

!-------------------------------------------------------------------------------------------------
! read numerical parameters and do sanity checks
  num_grid => config_numerics%get('grid',defaultVal=emptyDict)

  num%update_gamma    = num_grid%get_asBool ('update_gamma',   defaultVal=.false.)
  num%eps_div_atol    = num_grid%get_asFloat('eps_div_atol',   defaultVal=1.0e-4_pReal)
  num%eps_div_rtol    = num_grid%get_asFloat('eps_div_rtol',   defaultVal=5.0e-4_pReal)
  num%eps_curl_atol   = num_grid%get_asFloat('eps_curl_atol',  defaultVal=1.0e-10_pReal)
  num%eps_curl_rtol   = num_grid%get_asFloat('eps_curl_rtol',  defaultVal=5.0e-4_pReal)
  num%eps_stress_atol = num_grid%get_asFloat('eps_stress_atol',defaultVal=1.0e3_pReal)
  num%eps_stress_rtol = num_grid%get_asFloat('eps_stress_rtol',defaultVal=1.0e-3_pReal)
  num%itmin           = num_grid%get_asInt  ('itmin',          defaultVal=1)
  num%itmax           = num_grid%get_asInt  ('itmax',          defaultVal=250)
  num%alpha           = num_grid%get_asFloat('alpha',          defaultVal=1.0_pReal)
  num%beta            = num_grid%get_asFloat('beta',           defaultVal=1.0_pReal)

  if (num%eps_div_atol <= 0.0_pReal)                      call IO_error(301,ext_msg='eps_div_atol')
  if (num%eps_div_rtol < 0.0_pReal)                       call IO_error(301,ext_msg='eps_div_rtol')
  if (num%eps_curl_atol <= 0.0_pReal)                     call IO_error(301,ext_msg='eps_curl_atol')
  if (num%eps_curl_rtol < 0.0_pReal)                      call IO_error(301,ext_msg='eps_curl_rtol')
  if (num%eps_stress_atol <= 0.0_pReal)                   call IO_error(301,ext_msg='eps_stress_atol')
  if (num%eps_stress_rtol < 0.0_pReal)                    call IO_error(301,ext_msg='eps_stress_rtol')
  if (num%itmax <= 1)                                     call IO_error(301,ext_msg='itmax')
  if (num%itmin > num%itmax .or. num%itmin < 1)           call IO_error(301,ext_msg='itmin')
  if (num%alpha <= 0.0_pReal .or. num%alpha >  2.0_pReal) call IO_error(301,ext_msg='alpha')
  if (num%beta < 0.0_pReal .or. num%beta > 2.0_pReal)     call IO_error(301,ext_msg='beta')

!--------------------------------------------------------------------------------------------------
! set default and user defined options for PETSc
  call PetscOptionsInsertString(PETSC_NULL_OPTIONS,'-mechanical_snes_type ngmres',err_PETSc)
  CHKERRQ(err_PETSc)
  call PetscOptionsInsertString(PETSC_NULL_OPTIONS,num_grid%get_asString('petsc_options',defaultVal=''),err_PETSc)
  CHKERRQ(err_PETSc)

!--------------------------------------------------------------------------------------------------
! allocate global fields
  allocate(F_lastInc    (3,3,grid(1),grid(2),grid3),source = 0.0_pReal)
  allocate(Fdot         (3,3,grid(1),grid(2),grid3),source = 0.0_pReal)
  allocate(F_tau_lastInc(3,3,grid(1),grid(2),grid3),source = 0.0_pReal)
  allocate(F_tauDot     (3,3,grid(1),grid(2),grid3),source = 0.0_pReal)

!--------------------------------------------------------------------------------------------------
! initialize solver specific parts of PETSc
  call SNESCreate(PETSC_COMM_WORLD,SNES_mechanical,err_PETSc); CHKERRQ(err_PETSc)
  call SNESSetOptionsPrefix(SNES_mechanical,'mechanical_',err_PETSc)
  CHKERRQ(err_PETSc)
  localK            = 0_pPetscInt
  localK(worldrank) = int(grid3,pPetscInt)
  call MPI_Allreduce(MPI_IN_PLACE,localK,worldsize,MPI_INTEGER,MPI_SUM,MPI_COMM_WORLD,err_MPI)
  if (err_MPI /= 0_MPI_INTEGER_KIND) error stop 'MPI error'
  call DMDACreate3d(PETSC_COMM_WORLD, &
         DM_BOUNDARY_NONE, DM_BOUNDARY_NONE, DM_BOUNDARY_NONE, &                                    ! cut off stencil at boundary
         DMDA_STENCIL_BOX, &                                                                        ! Moore (26) neighborhood around central point
         int(grid(1),pPetscInt),int(grid(2),pPetscInt),int(grid(3),pPetscInt), &                    ! global grid
         1_pPetscInt, 1_pPetscInt, int(worldsize,pPetscInt), &
         18_pPetscInt, 0_pPetscInt, &                                                               ! #dof (2xtensor), ghost boundary width (domain overlap)
         [int(grid(1),pPetscInt)],[int(grid(2),pPetscInt)],localK, &                                ! local grid
         da,err_PETSc)                                                                              ! handle, error
  CHKERRQ(err_PETSc)
  call DMsetFromOptions(da,err_PETSc); CHKERRQ(err_PETSc)
  call DMsetUp(da,err_PETSc); CHKERRQ(err_PETSc)
  call DMcreateGlobalVector(da,solution_vec,err_PETSc); CHKERRQ(err_PETSc)                          ! global solution vector (grid x 18, i.e. every def grad tensor)
  call DMDASNESsetFunctionLocal(da,INSERT_VALUES,formResidual,PETSC_NULL_SNES,err_PETSc)            ! residual vector of same shape as solution vector
  CHKERRQ(err_PETSc)
  call SNESsetConvergenceTest(SNES_mechanical,converged,PETSC_NULL_SNES,PETSC_NULL_FUNCTION,err_PETSc) ! specify custom convergence check function "converged"
  CHKERRQ(err_PETSc)
  call SNESSetDM(SNES_mechanical,da,err_PETSc); CHKERRQ(err_PETSc)
  call SNESsetFromOptions(SNES_mechanical,err_PETSc); CHKERRQ(err_PETSc)                            ! pull it all together with additional CLI arguments

!--------------------------------------------------------------------------------------------------
! init fields
  call DMDAVecGetArrayF90(da,solution_vec,FandF_tau,err_PETSc); CHKERRQ(err_PETSc)                  ! places pointer on PETSc data
  F     => FandF_tau(0: 8,:,:,:)
  F_tau => FandF_tau(9:17,:,:,:)

  restartRead: if (interface_restartInc > 0) then
    print'(/,1x,a,i0,a)', 'reading restart data of increment ', interface_restartInc, ' from file'

    fileHandle  = HDF5_openFile(getSolverJobName()//'_restart.hdf5','r')
    groupHandle = HDF5_openGroup(fileHandle,'solver')

    call HDF5_read(P_aim,groupHandle,'P_aim',.false.)
    call MPI_Bcast(P_aim,9_MPI_INTEGER_KIND,MPI_DOUBLE,0_MPI_INTEGER_KIND,MPI_COMM_WORLD,err_MPI)
    if (err_MPI /= 0_MPI_INTEGER_KIND) error stop 'MPI error'
    call HDF5_read(F_aim,groupHandle,'F_aim',.false.)
    call MPI_Bcast(F_aim,9_MPI_INTEGER_KIND,MPI_DOUBLE,0_MPI_INTEGER_KIND,MPI_COMM_WORLD,err_MPI)
    if (err_MPI /= 0_MPI_INTEGER_KIND) error stop 'MPI error'
    call HDF5_read(F_aim_lastInc,groupHandle,'F_aim_lastInc',.false.)
    call MPI_Bcast(F_aim_lastInc,9_MPI_INTEGER_KIND,MPI_DOUBLE,0_MPI_INTEGER_KIND,MPI_COMM_WORLD,err_MPI)
    if (err_MPI /= 0_MPI_INTEGER_KIND) error stop 'MPI error'
    call HDF5_read(F_aimDot,groupHandle,'F_aimDot',.false.)
    call MPI_Bcast(F_aimDot,9_MPI_INTEGER_KIND,MPI_DOUBLE,0_MPI_INTEGER_KIND,MPI_COMM_WORLD,err_MPI)
    if (err_MPI /= 0_MPI_INTEGER_KIND) error stop 'MPI error'
    call HDF5_read(F,groupHandle,'F')
    call HDF5_read(F_lastInc,groupHandle,'F_lastInc')
    call HDF5_read(F_tau,groupHandle,'F_tau')
    call HDF5_read(F_tau_lastInc,groupHandle,'F_tau_lastInc')

  elseif (interface_restartInc == 0) then restartRead
    F_lastInc = spread(spread(spread(math_I3,3,grid(1)),4,grid(2)),5,grid3)                         ! initialize to identity
    F = reshape(F_lastInc,[9,grid(1),grid(2),grid3])
    F_tau = 2.0_pReal*F
    F_tau_lastInc = 2.0_pReal*F_lastInc
  end if restartRead

  homogenization_F0 = reshape(F_lastInc, [3,3,product(grid(1:2))*grid3])                            ! set starting condition for homogenization_mechanical_response
  call utilities_updateCoords(reshape(F,shape(F_lastInc)))
  call utilities_constitutiveResponse(P,P_av,C_volAvg,C_minMaxAvg, &                                ! stress field, stress avg, global average of stiffness and (min+max)/2
                                      reshape(F,shape(F_lastInc)), &                                ! target F
                                      0.0_pReal)                                                    ! time increment
  call DMDAVecRestoreArrayF90(da,solution_vec,FandF_tau,err_PETSc)                                  ! deassociate pointer
  CHKERRQ(err_PETSc)

  restartRead2: if (interface_restartInc > 0) then
    print'(1x,a,i0,a)', 'reading more restart data of increment ', interface_restartInc, ' from file'
    call HDF5_read(C_volAvg,groupHandle,'C_volAvg',.false.)
    call MPI_Bcast(C_volAvg,81_MPI_INTEGER_KIND,MPI_DOUBLE,0_MPI_INTEGER_KIND,MPI_COMM_WORLD,err_MPI)
    if (err_MPI /= 0_MPI_INTEGER_KIND) error stop 'MPI error'
    call HDF5_read(C_volAvgLastInc,groupHandle,'C_volAvgLastInc',.false.)
    call MPI_Bcast(C_volAvgLastInc,81_MPI_INTEGER_KIND,MPI_DOUBLE,0_MPI_INTEGER_KIND,MPI_COMM_WORLD,err_MPI)
    if (err_MPI /= 0_MPI_INTEGER_KIND) error stop 'MPI error'

    call HDF5_closeGroup(groupHandle)
    call HDF5_closeFile(fileHandle)

    call MPI_File_open(MPI_COMM_WORLD, trim(getSolverJobName())//'.C_ref', &
                       MPI_MODE_RDONLY,MPI_INFO_NULL,fileUnit,err_MPI)
    if (err_MPI /= 0_MPI_INTEGER_KIND) error stop 'MPI error'
    call MPI_File_read(fileUnit,C_minMaxAvg,81_MPI_INTEGER_KIND,MPI_DOUBLE,MPI_STATUS_IGNORE,err_MPI)
    if (err_MPI /= 0_MPI_INTEGER_KIND) error stop 'MPI error'
    call MPI_File_close(fileUnit,err_MPI)
    if (err_MPI /= 0_MPI_INTEGER_KIND) error stop 'MPI error'
  end if restartRead2

  call utilities_updateGamma(C_minMaxAvg)
  call utilities_saveReferenceStiffness
  C_scale = C_minMaxAvg
  S_scale = math_invSym3333(C_minMaxAvg)

end subroutine grid_mechanical_spectral_polarisation_init


!--------------------------------------------------------------------------------------------------
!> @brief solution for the Polarisation scheme with internal iterations
!--------------------------------------------------------------------------------------------------
function grid_mechanical_spectral_polarisation_solution(incInfoIn) result(solution)

!--------------------------------------------------------------------------------------------------
! input data for solution
  character(len=*), intent(in) :: &
    incInfoIn
  type(tSolutionState) :: &
    solution
!--------------------------------------------------------------------------------------------------
! PETSc Data
  PetscErrorCode :: err_PETSc
  SNESConvergedReason :: reason

  incInfo = incInfoIn

!--------------------------------------------------------------------------------------------------
! update stiffness (and gamma operator)
  S = utilities_maskedCompliance(params%rotation_BC,params%stress_mask,C_volAvg)
  if (num%update_gamma) then
    call utilities_updateGamma(C_minMaxAvg)
    C_scale = C_minMaxAvg
    S_scale = math_invSym3333(C_minMaxAvg)
  end if

  call SNESSolve(SNES_mechanical,PETSC_NULL_VEC,solution_vec,err_PETSc)
  CHKERRQ(err_PETSc)
  call SNESGetConvergedReason(SNES_mechanical,reason,err_PETSc)
  CHKERRQ(err_PETSc)

  solution%converged = reason > 0
  solution%iterationsNeeded = totalIter
  solution%termIll = terminallyIll
  terminallyIll = .false.
  P_aim = merge(P_av,P_aim,params%stress_mask)

end function grid_mechanical_spectral_polarisation_solution


!--------------------------------------------------------------------------------------------------
!> @brief forwarding routine
!> @details find new boundary conditions and best F estimate for end of current timestep
!--------------------------------------------------------------------------------------------------
subroutine grid_mechanical_spectral_polarisation_forward(cutBack,guess,Delta_t,Delta_t_old,t_remaining,&
                                                   deformation_BC,stress_BC,rotation_BC)

  logical,                  intent(in) :: &
    cutBack, &
    guess
  real(pReal),              intent(in) :: &
    Delta_t_old, &
    Delta_t, &
    t_remaining                                                                                     !< remaining time of current load case
  type(tBoundaryCondition), intent(in) :: &
    stress_BC, &
    deformation_BC
  type(rotation),           intent(in) :: &
    rotation_BC
  PetscErrorCode :: err_PETSc
  PetscScalar, pointer, dimension(:,:,:,:) :: FandF_tau, F, F_tau
  integer :: i, j, k
  real(pReal), dimension(3,3) :: F_lambda33


  call DMDAVecGetArrayF90(da,solution_vec,FandF_tau,err_PETSc); CHKERRQ(err_PETSc)
  F     => FandF_tau(0: 8,:,:,:)
  F_tau => FandF_tau(9:17,:,:,:)

  if (cutBack) then
    C_volAvg    = C_volAvgLastInc
    C_minMaxAvg = C_minMaxAvgLastInc
  else
    C_volAvgLastInc    = C_volAvg
    C_minMaxAvgLastInc = C_minMaxAvg

    F_aimDot = merge(merge(.0_pReal,(F_aim-F_aim_lastInc)/Delta_t_old,stress_BC%mask),.0_pReal,guess)  ! estimate deformation rate for prescribed stress components
    F_aim_lastInc = F_aim

    !-----------------------------------------------------------------------------------------------
    ! calculate rate for aim
    if     (deformation_BC%myType=='L') then                                                        ! calculate F_aimDot from given L and current F
      F_aimDot = F_aimDot &
               + matmul(merge(.0_pReal,deformation_BC%values,deformation_BC%mask),F_aim_lastInc)
    elseif (deformation_BC%myType=='dot_F') then                                                    ! F_aimDot is prescribed
      F_aimDot = F_aimDot &
               + merge(.0_pReal,deformation_BC%values,deformation_BC%mask)
    elseif (deformation_BC%myType=='F') then                                                        ! aim at end of load case is prescribed
      F_aimDot = F_aimDot &
               + merge(.0_pReal,(deformation_BC%values - F_aim_lastInc)/t_remaining,deformation_BC%mask)
    end if

    Fdot     = utilities_calculateRate(guess, &
                                       F_lastInc,reshape(F,[3,3,grid(1),grid(2),grid3]),Delta_t_old, &
                                       rotation_BC%rotate(F_aimDot,active=.true.))
    F_tauDot = utilities_calculateRate(guess, &
                                       F_tau_lastInc,reshape(F_tau,[3,3,grid(1),grid(2),grid3]), Delta_t_old, &
                                       rotation_BC%rotate(F_aimDot,active=.true.))
    F_lastInc     = reshape(F,    [3,3,grid(1),grid(2),grid3])
    F_tau_lastInc = reshape(F_tau,[3,3,grid(1),grid(2),grid3])

    homogenization_F0 = reshape(F,[3,3,product(grid(1:2))*grid3])
  end if

!--------------------------------------------------------------------------------------------------
! update average and local deformation gradients
  F_aim = F_aim_lastInc + F_aimDot * Delta_t
  if (stress_BC%myType=='P')     P_aim = P_aim &
                                      + merge(.0_pReal,(stress_BC%values - P_aim)/t_remaining,stress_BC%mask)*Delta_t
  if (stress_BC%myType=='dot_P') P_aim = P_aim &
                                      + merge(.0_pReal,stress_BC%values,stress_BC%mask)*Delta_t

  F = reshape(utilities_forwardField(Delta_t,F_lastInc,Fdot, &                                      ! estimate of F at end of time+Delta_t that matches rotated F_aim on average
                                     rotation_BC%rotate(F_aim,active=.true.)),&
              [9,grid(1),grid(2),grid3])
  if (guess) then
     F_tau = reshape(Utilities_forwardField(Delta_t,F_tau_lastInc,F_taudot), &
                     [9,grid(1),grid(2),grid3])                                                     ! does not have any average value as boundary condition
   else
    do k = 1, grid3; do j = 1, grid(2); do i = 1, grid(1)
       F_lambda33 = reshape(F_tau(1:9,i,j,k)-F(1:9,i,j,k),[3,3])
       F_lambda33 = math_I3 &
                  + math_mul3333xx33(S_scale,0.5_pReal*matmul(F_lambda33, &
                    math_mul3333xx33(C_scale,matmul(transpose(F_lambda33),F_lambda33)-math_I3)))
       F_tau(1:9,i,j,k) = reshape(F_lambda33,[9])+F(1:9,i,j,k)
    end do; end do; end do
  end if

  call DMDAVecRestoreArrayF90(da,solution_vec,FandF_tau,err_PETSc)
  CHKERRQ(err_PETSc)

!--------------------------------------------------------------------------------------------------
! set module wide available data
  params%stress_mask = stress_BC%mask
  params%rotation_BC = rotation_BC
  params%Delta_t     = Delta_t

end subroutine grid_mechanical_spectral_polarisation_forward


!--------------------------------------------------------------------------------------------------
!> @brief Update coordinates
!--------------------------------------------------------------------------------------------------
subroutine grid_mechanical_spectral_polarisation_updateCoords

  PetscErrorCode :: err_PETSc
  PetscScalar, dimension(:,:,:,:), pointer :: FandF_tau

  call DMDAVecGetArrayF90(da,solution_vec,FandF_tau,err_PETSc)
  CHKERRQ(err_PETSc)
  call utilities_updateCoords(FandF_tau(0:8,:,:,:))
  call DMDAVecRestoreArrayF90(da,solution_vec,FandF_tau,err_PETSc)
  CHKERRQ(err_PETSc)

end subroutine grid_mechanical_spectral_polarisation_updateCoords


!--------------------------------------------------------------------------------------------------
!> @brief Write current solver and constitutive data for restart to file
!--------------------------------------------------------------------------------------------------
subroutine grid_mechanical_spectral_polarisation_restartWrite

  PetscErrorCode :: err_PETSc
  integer(HID_T) :: fileHandle, groupHandle
  PetscScalar, dimension(:,:,:,:), pointer :: FandF_tau, F, F_tau

  call DMDAVecGetArrayF90(da,solution_vec,FandF_tau,err_PETSc); CHKERRQ(err_PETSc)
  F     => FandF_tau(0: 8,:,:,:)
  F_tau => FandF_tau(9:17,:,:,:)

  print'(1x,a)', 'writing solver data required for restart to file'; flush(IO_STDOUT)

  fileHandle  = HDF5_openFile(getSolverJobName()//'_restart.hdf5','w')
  groupHandle = HDF5_addGroup(fileHandle,'solver')
  call HDF5_write(F,groupHandle,'F')
  call HDF5_write(F_lastInc,groupHandle,'F_lastInc')
  call HDF5_write(F_tau,groupHandle,'F_tau')
  call HDF5_write(F_tau_lastInc,groupHandle,'F_tau_lastInc')
  call HDF5_closeGroup(groupHandle)
  call HDF5_closeFile(fileHandle)

  if (worldrank == 0) then
    fileHandle  = HDF5_openFile(getSolverJobName()//'_restart.hdf5','a',.false.)
    groupHandle = HDF5_openGroup(fileHandle,'solver')
    call HDF5_write(F_aim,groupHandle,'P_aim',.false.)
    call HDF5_write(F_aim,groupHandle,'F_aim',.false.)
    call HDF5_write(F_aim_lastInc,groupHandle,'F_aim_lastInc',.false.)
    call HDF5_write(F_aimDot,groupHandle,'F_aimDot',.false.)
    call HDF5_write(C_volAvg,groupHandle,'C_volAvg',.false.)
    call HDF5_write(C_volAvgLastInc,groupHandle,'C_volAvgLastInc',.false.)
    call HDF5_closeGroup(groupHandle)
    call HDF5_closeFile(fileHandle)
  end if

  if (num%update_gamma) call utilities_saveReferenceStiffness

  call DMDAVecRestoreArrayF90(da,solution_vec,FandF_tau,err_PETSc)
  CHKERRQ(err_PETSc)

end subroutine grid_mechanical_spectral_polarisation_restartWrite


!--------------------------------------------------------------------------------------------------
!> @brief convergence check
!--------------------------------------------------------------------------------------------------
subroutine converged(snes_local,PETScIter,devNull1,devNull2,devNull3,reason,dummy,err_PETSc)

  SNES :: snes_local
  PetscInt,  intent(in) :: PETScIter
  PetscReal, intent(in) :: &
    devNull1, &
    devNull2, &
    devNull3
  SNESConvergedReason :: reason
  PetscObject :: dummy
  PetscErrorCode :: err_PETSc
  real(pReal) :: &
    curlTol, &
    divTol, &
    BCTol

  curlTol = max(maxval(abs(F_aim-math_I3))*num%eps_curl_rtol, num%eps_curl_atol)
  divTol = max(maxval(abs(P_av))*num%eps_div_rtol, num%eps_div_atol)
  BCTol = max(maxval(abs(P_av))*num%eps_stress_rtol, num%eps_stress_atol)

  if ((totalIter >= num%itmin .and. all([err_div/divTol, err_curl/curlTol, err_BC/BCTol] < 1.0_pReal)) &
       .or. terminallyIll) then
    reason = 1
  elseif (totalIter >= num%itmax) then
    reason = -1
  else
    reason = 0
  end if

  print'(/,1x,a)', '... reporting .............................................................'
  print'(/,1x,a,f12.2,a,es8.2,a,es9.2,a)', 'error divergence = ', &
            err_div/divTol,  ' (',err_div, ' / m, tol = ',divTol,')'
  print  '(1x,a,f12.2,a,es8.2,a,es9.2,a)', 'error curl       = ', &
            err_curl/curlTol,' (',err_curl,' -,   tol = ',curlTol,')'
  print  '(1x,a,f12.2,a,es8.2,a,es9.2,a)', 'error stress BC  = ', &
            err_BC/BCTol,    ' (',err_BC,  ' Pa,  tol = ',BCTol,')'
  print'(/,1x,a)', '==========================================================================='
  flush(IO_STDOUT)
  err_PETSc = 0

end subroutine converged


!--------------------------------------------------------------------------------------------------
!> @brief forms the residual vector
!--------------------------------------------------------------------------------------------------
subroutine formResidual(in, FandF_tau, &
                        r, dummy,err_PETSc)

  DMDALocalInfo, dimension(DMDA_LOCAL_INFO_SIZE) :: in                                              !< DMDA info (needs to be named "in" for macros like XRANGE to work)
  PetscScalar, dimension(3,3,2,XG_RANGE,YG_RANGE,ZG_RANGE), &
    target, intent(in) :: FandF_tau
  PetscScalar, dimension(3,3,2,X_RANGE,Y_RANGE,Z_RANGE),&
    target, intent(out) :: r                                                                        !< residuum field
  PetscScalar, pointer, dimension(:,:,:,:,:) :: &
    F, &
    F_tau, &
    r_F, &
    r_F_tau
  PetscInt :: &
    PETScIter, &
    nfuncs
  PetscObject :: dummy
  PetscErrorCode :: err_PETSc
  integer(MPI_INTEGER_KIND) :: err_MPI
  integer :: &
    i, j, k, e

!---------------------------------------------------------------------------------------------------

  F       => FandF_tau(1:3,1:3,1,&
                       XG_RANGE,YG_RANGE,ZG_RANGE)
  F_tau   => FandF_tau(1:3,1:3,2,&
                       XG_RANGE,YG_RANGE,ZG_RANGE)
  r_F     => r(1:3,1:3,1,&
               X_RANGE, Y_RANGE, Z_RANGE)
  r_F_tau => r(1:3,1:3,2,&
               X_RANGE, Y_RANGE, Z_RANGE)

  F_av = sum(sum(sum(F,dim=5),dim=4),dim=3) * wgt
  call MPI_Allreduce(MPI_IN_PLACE,F_av,9_MPI_INTEGER_KIND,MPI_DOUBLE,MPI_SUM,MPI_COMM_WORLD,err_MPI)
  if (err_MPI /= 0_MPI_INTEGER_KIND) error stop 'MPI error'

  call SNESGetNumberFunctionEvals(SNES_mechanical,nfuncs,err_PETSc)
  CHKERRQ(err_PETSc)
  call SNESGetIterationNumber(SNES_mechanical,PETScIter,err_PETSc)
  CHKERRQ(err_PETSc)

  if (nfuncs == 0 .and. PETScIter == 0) totalIter = -1                                              ! new increment

!--------------------------------------------------------------------------------------------------
! begin of new iteration
  newIteration: if (totalIter <= PETScIter) then
    totalIter = totalIter + 1
    print'(1x,a,3(a,i0))', trim(incInfo), ' @ Iteration ', num%itmin, '≤',totalIter, '≤', num%itmax
    if (debugRotation) print'(/,1x,a,/,2(3(f12.7,1x)/),3(f12.7,1x))', &
      'deformation gradient aim (lab) =', transpose(params%rotation_BC%rotate(F_aim,active=.true.))
    print'(/,1x,a,/,2(3(f12.7,1x)/),3(f12.7,1x))', &
      'deformation gradient aim       =', transpose(F_aim)
    flush(IO_STDOUT)
  end if newIteration

!--------------------------------------------------------------------------------------------------
!
  tensorField_real = 0.0_pReal
  do k = 1, grid3; do j = 1, grid(2); do i = 1, grid(1)
    tensorField_real(1:3,1:3,i,j,k) = &
      num%beta*math_mul3333xx33(C_scale,F(1:3,1:3,i,j,k) - math_I3) -&
      num%alpha*matmul(F(1:3,1:3,i,j,k), &
                         math_mul3333xx33(C_scale,F_tau(1:3,1:3,i,j,k) - F(1:3,1:3,i,j,k) - math_I3))
  end do; end do; end do

!--------------------------------------------------------------------------------------------------
! doing convolution in Fourier space
  call utilities_FFTtensorForward
  call utilities_fourierGammaConvolution(params%rotation_BC%rotate(num%beta*F_aim,active=.true.))
  call utilities_FFTtensorBackward

!--------------------------------------------------------------------------------------------------
! constructing residual
  r_F_tau = num%beta*F - tensorField_real(1:3,1:3,1:grid(1),1:grid(2),1:grid3)

!--------------------------------------------------------------------------------------------------
! evaluate constitutive response
  call utilities_constitutiveResponse(r_F, &                                                        ! "residuum" gets field of first PK stress (to save memory)
                                      P_av,C_volAvg,C_minMaxAvg, &
                                      F - r_F_tau/num%beta,params%Delta_t,params%rotation_BC)
  call MPI_Allreduce(MPI_IN_PLACE,terminallyIll,1_MPI_INTEGER_KIND,MPI_LOGICAL,MPI_LOR,MPI_COMM_WORLD,err_MPI)

!--------------------------------------------------------------------------------------------------
! stress BC handling
  F_aim = F_aim - math_mul3333xx33(S, P_av - P_aim)                                                 ! S = 0.0 for no bc
  err_BC = maxval(abs(merge(math_mul3333xx33(C_scale,F_aim-params%rotation_BC%rotate(F_av)), &
                            P_av-P_aim, &
                            params%stress_mask)))
! calculate divergence
  tensorField_real = 0.0_pReal
  tensorField_real(1:3,1:3,1:grid(1),1:grid(2),1:grid3) = r_F                                       !< stress field in disguise
  call utilities_FFTtensorForward
  err_div = utilities_divergenceRMS()                                                               !< root mean squared error in divergence of stress

!--------------------------------------------------------------------------------------------------
! constructing residual
  e = 0
  do k = 1, grid3; do j = 1, grid(2); do i = 1, grid(1)
    e = e + 1
    r_F(1:3,1:3,i,j,k) = &
      math_mul3333xx33(math_invSym3333(homogenization_dPdF(1:3,1:3,1:3,1:3,e) + C_scale), &
                       r_F(1:3,1:3,i,j,k) - matmul(F(1:3,1:3,i,j,k), &
                       math_mul3333xx33(C_scale,F_tau(1:3,1:3,i,j,k) - F(1:3,1:3,i,j,k) - math_I3))) &
                       + r_F_tau(1:3,1:3,i,j,k)
  end do; end do; end do

!--------------------------------------------------------------------------------------------------
! calculating curl
  tensorField_real = 0.0_pReal
  tensorField_real(1:3,1:3,1:grid(1),1:grid(2),1:grid3) = F
  call utilities_FFTtensorForward
  err_curl = utilities_curlRMS()

end subroutine formResidual

end module grid_mechanical_spectral_polarisation
